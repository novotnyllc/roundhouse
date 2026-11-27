# shellcheck shell=bash
# State capture stays in this instance's store.run and the existing jj working copy.

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
    codex:*) [[ ${1#*:} =~ ^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*@[A-Za-z0-9_-]+$ ]] ;;
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
  local id=$1:$2 path
  path=$(fleet_agent_pending_path "$id") || return 1
  fleet_capture_json_write "$path" "{\"id\":\"$id\"}"
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
  def listing($agent):
    [.[] | select(.kind == "plugin_manager" and .data.agent == $agent)] as $manager |
    [.[] | select(.kind == "plugin" and .data.agent == $agent and .data.inventory_source == "manager")] as $rows |
    if ($manager | length) == 1 and $manager[0].status == "present" and
      $manager[0].data.authoritative == true and $manager[0].data.installed_count == ($rows | length) and
      all($rows[]; .status == "present" and (.data.manager_id | id_ok) and
        (.data.enabled | type) == "boolean" and
        .data.manager_id == (.data.name + "@" + .data.marketplace)) and
      ($agent != "claude" or all($rows[]; (.data.scope | type) == "string" and .data.scope != ""))
    then [$rows[].data | select($agent != "claude" or .scope == "user")] |
      if ([.[].manager_id] | length == (unique | length)) then INDEX(.manager_id) else null end
    else null end;'

fleet_capture_claude_observe() {
  local listing=$1 installed settings installed_path settings_path known known_path
  installed_path="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/installed_plugins.json"
  settings_path=$(fleet_run_settings_path)
  known_path="${installed_path%/*}/known_marketplaces.json"
  installed=$(fleet_run_installed_plugins) || return 1
  if [ -e "$installed_path" ]; then
    jq -es 'length == 1 and (.[0].plugins | type) == "object"' "$installed_path" >/dev/null || return 1
  fi
  settings=$(fleet_capture_json_read "$settings_path" '{}') || return 1
  known=$(fleet_capture_json_read "$known_path" '{}') || return 1
  local missing id path
  missing=$(jq -rc --argjson listing "$listing" --argjson settings "$settings" '
    to_entries[] | .key as $id | select($listing[$id] == null) |
    .value[] | select(.scope == "user") |
    [$id, (.installPath // ""), ($settings.enabledPlugins[$id] | type)] | @tsv' <<<"$installed") || return 1
  local known_state
  while IFS=$'\t' read -r id path known_state; do
    [ -n "$id" ] || continue
    # A missing CLI row is admissible only for a damaged install with an
    # intact user record and explicit enabled state.
    [ "$known_state" = boolean ] && [ -n "$path" ] && [ ! -e "$path" ] || return 1
  done <<<"$missing"
  jq -cn --argjson listing "$listing" --argjson installed "$installed" \
    --argjson settings "$settings" --argjson known "$known" "$fleet_capture_listing_filter"'
    def local_source:
      (.source // "") as $kind | (.url // .path // "") as $locator |
      ($kind | IN("directory","file","local","path")) or
      ($locator | test("^(file:|[./~]|[a-zA-Z]:[/\\\\])"));
    ($settings.enabledPlugins // {}) as $enabled |
    ([$known, ($settings.extraKnownMarketplaces // {})] |
      [ .[] | to_entries[] | select(.value.source // {} | local_source) | .key ] |
      unique) as $local_markets |
    if ($enabled | type) != "object" or any($enabled[]; type != "boolean") or
      any($installed | to_entries[]; (.key | id_ok | not) or
        (.value | type) != "array" or (.value | length) == 0 or
        any(.value[]; type != "object" or (.scope | type) != "string")) or
      any($listing | keys[]; . as $id | $installed[$id] == null)
    then error("Claude records and plugin list disagree")
    else $installed | to_entries | map(
      .key as $id | ($id | split("@")[1]) as $market |
      [.value[] | select(.scope == "user")] as $user |
      {key:$id, value:{
        value:(if ($user | length) != 1 then "unknown"
          elif ($enabled[$id] // $listing[$id].enabled) == true and $enabled[$id] != false
          then "enabled" else "disabled" end),
        marketplace:$market, user_scope:(($user | length) > 0),
        stageable:(($user | length) == 1 and ($local_markets | index($market)) == null)
      }}) | from_entries as $records |
      {plugins:(($enabled | with_entries(select(.key | id_ok) |
        .value = {value:"unknown",stageable:false})) + $records),
       local_markets:$local_markets} end'
}

fleet_capture_codex_markets() {
  local listed
  listed=$(bounded_query codex plugin marketplace list --json 2>/dev/null) || return 1
  printf '%s\n' "$listed" | jq -ce '
    (if type == "array" then . else .marketplaces end) |
    if type != "array" then error("invalid marketplace list") else . end |
    map(select(.name | type == "string" and test("^[A-Za-z0-9_-]+$"))) |
    group_by(.name) | map({
      key:.[0].name,
      value:(if length != 1 or (.[0].marketplaceSource | type) != "object" or
        (.[0].marketplaceSource.sourceType | type) != "string" or
        (.[0].marketplaceSource.source | type) != "string" then null
        else (.[0].marketplaceSource |
          if .sourceType == "git" and
            (.source | test("^((https?|ssh|git)://[^/[:space:]]+/|[^@/[:space:]]+@[^:/[:space:]]+:)[^[:space:]]+$")) then true
          elif (.sourceType | IN("directory","local","path","file","bundled")) or
            (.source | test("^(file:|[./~]|[a-zA-Z]:[/\\\\])")) then false
          else null end) end)
    }) |
    from_entries'
}

fleet_capture_codex_observe() {
  local listing=$1 markets=$2 config="${CODEX_HOME:-$HOME/.codex}/config.toml" registered='{}'
  if [ -e "$config" ]; then
    registered=$(yq -p=toml -o=json -I=0 '(.plugins // {}) | del(._default)' "$config") || return 1
  fi
  jq -ce --argjson registered "$registered" --argjson markets "$markets" '
    . as $listed |
    if ($registered | type) != "object" or
      any($registered | to_entries[];
        (.value | type) != "object" or ($listed[.key] == null) or
        ((.value | has("enabled")) and .value.enabled != $listed[.key].enabled))
    then error("Codex records and plugin list disagree")
    else with_entries(.key as $id | .value = {
      value:(if $registered[$id] == null then "unknown"
        elif .value.enabled then "enabled" else "disabled" end),
      marketplace:.value.marketplace, user_scope:($registered[$id] != null),
      stageable:($registered[$id] != null and $markets[.value.marketplace] == true)
    }) end' <<<"$listing"
}

fleet_capture_observe() {
  local lists claude codex markets retry=false claude_state='{"plugins":null,"local_markets":[]}'
  lists=$(jq -cs "$fleet_capture_listing_filter"'
    {claude:listing("claude"),codex:listing("codex"),
      retry:any(.[]; .kind == "plugin_manager" and .status == "unavailable")}' "$1") ||
    lists='{"claude":null,"codex":null,"retry":true}'
  claude=$(jq -c .claude <<<"$lists")
  codex=$(jq -c .codex <<<"$lists")
  markets='{}'
  if [ "$claude" != null ]; then
    claude_state=$(fleet_capture_claude_observe "$claude" 2>/dev/null) ||
      claude_state='{"plugins":null,"local_markets":[]}'
  fi
  if [ "$codex" != null ]; then
    markets=$(fleet_capture_codex_markets) || markets='{}'
    codex=$(fleet_capture_codex_observe "$codex" "$markets" 2>/dev/null) || codex=null
    if jq -e --argjson markets "$markets" 'any(.[]?; .user_scope and $markets[.marketplace] == null)' \
      >/dev/null <<<"$codex"; then retry=true; fi
  fi
  if jq -e '.retry' >/dev/null <<<"$lists" ||
    { jq -e '.plugins == null' >/dev/null <<<"$claude_state" &&
      [ -e "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/installed_plugins.json" ]; } ||
    { [ "$codex" = null ] && [ -e "${CODEX_HOME:-$HOME/.codex}/config.toml" ]; }; then
    retry=true
  fi
  jq -cn --argjson claude "$claude_state" --argjson codex "$codex" --argjson markets "$markets" \
    --argjson retry "$retry" \
    '{claude:$claude.plugins,claude_local_markets:$claude.local_markets,
      codex:$codex,codex_markets:$markets,retry:$retry}'
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
  printf '{"claude":null,"codex":null,"codex_markets":{},"retry":true}\n'
}

fleet_capture_authority_filter='
  def authoritative($observed; $baseline; $h):
    $observed[$h] != null and
    (any($observed[$h][]?; .value | IN("enabled","disabled")) or
      all($baseline | to_entries[] | select(.key | startswith($h + ":"));
        .value.value | IN("enabled","disabled") | not));'

fleet_capture_rows() {
  # Join desired item names to physical harness IDs. Claude can omit the
  # marketplace in YAML when the local inventory uniquely resolves its name.
  local definitions pending
  definitions=$(fleet_definitions_load "$1") || return 1
  pending=$(fleet_capture_pending_ids | jq -Rn '[inputs]') || return 1
  jq -cn --argjson desired "$2" --argjson observed "$3" --argjson baseline "$4" \
    --argjson defs "$definitions" --argjson pending "$pending" "$fleet_capture_authority_filter"'
    def state: if type == "object" and has("state") then .state
      elif type == "object" then "enabled" else . end;
    def market: if type == "object" then .marketplace else null end;
    def physical($h; $id): $h + ":" + $id;
    def plugin_rows($h; $category):
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
        ((.value | market) // ($defs[$category][$name] | market)) as $market |
        (if $h == "codex" or ($name | contains("@")) then [$name]
         elif $market != null then [$name + "@" + $market]
         else [$known_ids[] | select(startswith($name + "@"))] end) as $ids |
        (if ($ids | length) == 1 then $ids[0] else null end) as $id |
        ($category + "." + $name) as $item |
        {
          id:(if $id == null then null else physical($h; $id) end),
          item:$item, name:$name, harness:$h, ambiguous:(($ids | length) > 1),
          marketplace:($id // "" | split("@")[1] // ""),
          theirs:$theirs, ours:(if $unknown then "unknown"
            elif $id != null then ($local[$id].value // "absent")
            elif ($ids | length) == 0 and $theirs == "absent" then "absent"
            else "unresolved" end),
          stageable:($id != null and ($local[$id].stageable //
            ($local[$id] == null and
              (($id | split("@")[1]) as $id_market |
              if $h == "codex" then $observed.codex_markets[$id_market] == true
              else (($observed.claude_local_markets // []) | index($id_market)) == null end)))),
          base:((if $id == null then null else $base[physical($h; $id)] end) //
            (if $market == null and ($name | contains("@") | not) then $baseline[$item] else null end))
        }
      ] as $managed |
      $managed +
      [
        $known_ids[] as $id | ($id | split("@")) as $parts |
        (if $h == "codex" then $id else $parts[0] end) as $name |
        select(all($managed[]; .name != $name and .id != physical($h; $id))) |
        select($local[$id].user_scope != false or $base[physical($h; $id)] != null or
          ($pending_ids | index($id)) != null) |
        {
          id:physical($h; $id), item:($category + "." + $name), name:$name,
          harness:$h, marketplace:$parts[1], theirs:"missing",
          ours:(if $unknown then "unknown" else ($local[$id].value // "absent") end),
          stageable:($local[$id].stageable // false),
          base:($base[physical($h; $id)] // $baseline[$category + "." + $name])
        }
      ];
    plugin_rows("claude"; "plugins") + plugin_rows("codex"; "codex_plugins") |
    group_by(.id // .item) | map(if length == 1 then .[0]
      else .[] | .ambiguous = true end) |
    group_by(.item) | map((length > 1) as $duplicate | .[] |
      if $duplicate or .ambiguous == true then .ambiguous = true | .ours = "unknown" else . end)'
}

fleet_capture_initialized() {
  # Older baselines can only prove initialization for harnesses they recorded.
  jq -c '._initialized // {
    claude:any(keys[]; startswith("claude:")),
    codex:any(keys[]; startswith("codex:"))
  }' <<<"$1"
}

fleet_capture_declarations() (
  # yq emits files in input order; the last declaration in each tier wins.
  local layers=$1 host=$2 file paths
  paths=$(fleet_layer_files "$layers" "$host") || return 1
  [ -n "$paths" ] || { printf '{}\n'; return; }
  IFS='
'
  set -f
  # shellcheck disable=SC2086 # newline-separated paths
  set -- $paths
  for file; do [ ! -L "$file" ] || return 1; done
  local docs
  docs=$(yq ea -o=json -I=0 '{"path": filename, "plugins": .plugins, "codex_plugins": .codex_plugins}' "$@") || return 1
  jq -cs --arg root "$layers/" --arg host "$host" '
      reduce (.[] | (.path | ltrimstr($root)) as $path |
        (if $path == ("hosts/" + $host + ".yaml") or ($path | startswith("hosts/" + $host + "/"))
         then "pin" else "shared" end) as $tier |
        [(.plugins // {} | to_entries[] | select(.value != null) | "plugins." + .key),
         (.codex_plugins // {} | to_entries[] | select(.value != null) | "codex_plugins." + .key)][] |
        {item:.,path:$path,tier:$tier}) as $entry ({};
        .[$entry.item][$entry.tier] = $entry.path)' <<<"$docs"
)

fleet_capture_known_markets() {
  local defs
  defs=$(fleet_definitions_load "$1") || return 1
  jq -cn --argjson defs "$defs" --argjson desired "$2" --argjson declarations "$3" '
    [
      ($desired.plugins // {} | to_entries[] | select($declarations["plugins." + .key].shared != null) |
        .value | objects | .marketplace),
      ($defs.plugins // {} | .[] | objects | .marketplace),
      ($desired.codex_plugins // {} | keys[] | select($declarations["codex_plugins." + .].shared != null) | split("@")[1]),
      ($desired.policy.marketplaces // {} | if type == "object" then keys[] elif type == "array" then .[] else empty end)
    ] | map(strings) | unique'
}

fleet_capture_batch_id() {
  jq -cS 'sort_by(.id)' <<<"$1" | sha256_stream | cut -c1-20
}

fleet_capture_prepare() {
  local store=$1 host=$2 desired=$3 observed=$4 clean=$5 fetched=$6
  local layers=${8:-$1} dir baseline conflicts batch take discard declarations markets rows row
  local id item harness name theirs ours base stageable market pin path value decision marker first ambiguous
  local initialized enabled=true cap_active=false pending=false
  local candidates=() skip=() discard_done=()
  fleet_capture_skip='{}'
  fleet_capture_items='[]'
  fleet_capture_subject=
  fleet_capture_layers=$layers
  fleet_capture_host=$host
  fleet_capture_consume_batch=false
  fleet_capture_discards='[]'
  fleet_capture_before_observed=$observed
  fleet_capture_retry_unknown=$(jq -r '.retry == true' <<<"$observed") || return 1
  dir=$(fleet_instance_path store.run)
  baseline=$(fleet_capture_json_read "$dir/agent-baseline.json" '{}') || return 1
  initialized=$(fleet_capture_initialized "$baseline") || return 1
  conflicts=$(fleet_capture_json_read "$dir/agent-conflicts.json" '{}') || return 1
  batch=$(fleet_capture_json_read "$dir/agent-pending-confirm.json" '{}') || return 1
  take=$(fleet_capture_json_read "$dir/agent-take-local.json" '{}') || return 1
  discard=$(fleet_capture_json_read "$dir/agent-discard.json" '{}') || return 1
  declarations=$(fleet_capture_declarations "$layers" "$host") || return 1
  markets=$(fleet_capture_known_markets "$layers" "$desired" "$declarations") || return 1
  rows=$(fleet_capture_rows "$layers" "$desired" "$observed" "$baseline") || return 1
  if jq -e '.capture == false' <<<"$desired" >/dev/null; then enabled=false; fi
  local codex_enabled mirror host_default
  codex_enabled=$(jq -r '.policy.capture_codex == true' <<<"$desired")
  mirror=$(jq -r '.policy.capture_mirror_codex == true' <<<"$desired")
  host_default=$(jq -r '.default_agent_state // empty' <<<"$desired")
  while IFS=$'\t' read -r id item harness name theirs ours base stageable market pin path value decision first ambiguous; do
    [ -n "$item" ] || continue
    if [ "$ours" = unknown ]; then
      skip+=("$item")
      fleet_capture_retry_unknown=true
      if [ "$ambiguous" = true ]; then
        fleet_alert_write "$store" "$host" agent-capture-ambiguous agent-capture-ambiguous \
          "Multiple plugin identities or declarations resolve to $item. Holding this item." "$item" || :
      fi
      continue
    fi
    [ "$enabled" = true ] || continue
    [ "$ours" != unresolved ] || continue
    fleet_capture_id_valid "$id" || continue
    [ "$id" != claude:roundhouse@novotnyllc ] && [ "$id" != codex:roundhouse@novotnyllc ] || continue
    marker=$(fleet_agent_pending_path "$id") || return 1
    local saved batch_row
    saved=$(jq -c --arg id "$id" '.[$id] // null' <<<"$conflicts")
    batch_row=$(jq -c --arg id "$id" '[.items[]? | select(.id == $id)] | .[0] // null' <<<"$batch")
    if [ "$decision" = discard ] ||
      { [ "$batch_row" != null ] && jq -e '.discarded == true' <<<"$batch" >/dev/null; }; then
      if [ "$theirs" != missing ]; then
        [ -f "$marker" ] || fleet_agent_pending_mark "$harness" "${id#*:}" || return 1
      fi
      discard_done+=("$id" "$item")
      continue
    fi
    local legacy_marker=
    if [ "$harness" = claude ]; then
      legacy_marker=$(fleet_agent_pending_path "${id%@*}@__unqualified__") || return 1
    fi
    if [ "$decision" != take ]; then
      [ ! -e "$marker" ] && [ ! -e "$legacy_marker" ] || continue
    fi
    [ "$first" = false ] || continue
    if [ "$saved" != null ] && ! jq -e --arg theirs "$theirs" '.theirs == $theirs' <<<"$saved" >/dev/null; then
      fleet_alert_write "$store" "$host" agent-capture-conflict agent-capture-conflict \
        "Fleet value for $id changed again. The earlier displaced value was cleared." "$item" || :
      conflicts=$(jq -c --arg id "$id" 'del(.[$id])' <<<"$conflicts")
      fleet_capture_json_write "$dir/agent-conflicts.json" "$conflicts" || return 1
      saved=null
    fi
    if [ "$decision" = take ] && [ "$saved" != null ]; then
      value=$(jq -r .value <<<"$saved")
    fi
    local merged
    merged=$(fleet_merge3 "$base" "$ours" "$theirs")
    if [ "$decision" != take ]; then
      case $merged in local|conflict) ;; *) continue ;; esac
    fi
    if [ "$pin" != - ] && [ "$decision" != take ]; then
      skip+=("$item")
      fleet_alert_write "$store" "$host" agent-pinned-local-change agent-pinned-local-change \
        "$id is pinned on $host. Use roundhouse fleet-take-local $id to keep the local value or roundhouse fleet-discard $id to restore the pin." "$item" || :
      continue
    fi
    if [ -n "$host_default" ] && [ "$theirs" != missing ] &&
      [ "$pin" = - ] && [ "$decision" != take ]; then
      skip+=("$item")
      continue
    fi
    [ "$harness" != codex ] || [ "$codex_enabled" = true ] || continue
    if [ "$harness" = codex ] && jq -e --arg market "$market" \
      '.codex_markets[$market] == null' >/dev/null <<<"$observed"; then
      skip+=("$item")
      fleet_capture_retry_unknown=true
      continue
    fi
    [ "$stageable" = true ] || continue
    if ! jq -e --arg m "$market" 'index($m) != null' <<<"$markets" >/dev/null; then
      skip+=("$item")
      fleet_alert_write "$store" "$host" agent-capture-unknown-marketplace agent-capture-unknown-marketplace \
        "$id is local because the fleet has not declared $market." "$item" || :
      continue
    fi
    row=$(jq -cn --arg id "$id" --arg item "$item" --arg harness "$harness" \
      --arg marketplace "$market" --arg value "$value" --arg theirs "$theirs" \
      --arg path "$path" --arg name "$name" --arg pin "$pin" --arg decision "$decision" \
      '{id:$id,item:$item,harness:$harness,marketplace:$marketplace,value:$value,
        theirs:$theirs,path:(if $pin != "-" then $pin else $path end),name:$name,decision:$decision}')
    if [ "$merged" = conflict ] && [ "$decision" != take ]; then
      [ "$clean" = true ] && [ "$fetched" = true ] || { skip+=("$item"); continue; }
      if [ "$saved" = null ]; then
        conflicts=$(jq -c --argjson row "$row" '.[$row.id] = $row' <<<"$conflicts") || return 1
        fleet_capture_json_write "$dir/agent-conflicts.json" "$conflicts" || return 1
        fleet_alert_write "$store" "$host" agent-capture-conflict agent-capture-conflict \
          "$id changed on $host and in the fleet. The fleet value wins. Use roundhouse fleet-take-local $id to publish the displaced value." "$item" || :
      fi
      continue
    fi
    if [ "$value" = "$theirs" ]; then
      [ "$decision" != take ] || discard_done+=("$id" "$item")
      continue
    fi
    case $value in enabled|disabled|absent) ;; *) continue ;; esac
    skip+=("$item")
    candidates+=("$row")
  done < <(jq -r --argjson declarations "$declarations" --argjson take "$take" --argjson discard "$discard" \
    --argjson initialized "$initialized" '
    .[] | . as $r | ($declarations[.item] // {}) as $d |
    [.id // "-", .item, .harness, .name, .theirs, .ours,
      (if .base == null then "missing" elif .base.ignored then "ignored:" + .base.value else .base.value end),
      .stageable, (if .marketplace == "" then "-" else .marketplace end),
      $d.pin // "-", $d.shared // "fleet/99-canonical-agents.yaml", .ours,
      (if $discard[.id // "-"] == true or $discard[.item] == true then "discard"
       elif $take[.id // "-"] == true or $take[.item] == true then "take" else "derive" end),
      ($initialized[.harness] != true), (.ambiguous == true)]
    | @tsv' <<<"$rows")
  if [ "${#skip[@]}" -gt 0 ]; then
    fleet_capture_skip=$(printf '%s\n' "${skip[@]}" | jq -Rn '[inputs | {key:.,value:true}] | from_entries')
  fi
  [ "$enabled" = true ] || return 0
  if [ "${#discard_done[@]}" -gt 0 ]; then
    fleet_capture_discards=$(printf '%s\n' "${discard_done[@]}" | jq -Rn '[inputs] | unique')
  fi
  [ "$clean" = true ] && [ "$fetched" = true ] || return 0
  local staged count managed limits cap_limit bid accepted confirmed=false discarded=false
  staged=$(printf '%s\n' ${candidates[@]+"${candidates[@]}"} | jq -sc 'sort_by(.id)')
  if [ "$codex_enabled" = true ] && [ "$mirror" = true ]; then
    staged=$(jq -c --argjson d "$desired" --argjson o "$observed" --argjson declarations "$declarations" \
      --argjson baseline "$baseline" "$fleet_capture_authority_filter"'
      . as $items | . + [
        select(authoritative($o; $baseline; "codex")) |
        $items[] | select(.harness == "claude" and (.theirs | IN("missing","absent")) and .value != "absent"
          and ($declarations[.item].pin == null)) |
        (.id | ltrimstr("claude:")) as $id | ("codex_plugins." + $id) as $item |
        select(($o.codex[$id].value // "absent" | IN("enabled","disabled","absent"))
          and $o.codex_markets[.marketplace] == true and $d.codex_plugins[$id] == null
          and $declarations[$item].pin == null and all($items[]; .item != $item)) |
        . + {id:("codex:" + $id),item:$item,harness:"codex",name:$id,decision:"mirror",
          path:"fleet/99-canonical-agents.yaml"}
      ] | sort_by(.id)' <<<"$staged") || return 1
  fi
  count=$(jq 'length' <<<"$staged")
  if jq -e '.discarded == true' <<<"$batch" >/dev/null; then
    discarded=true
    if ! jq -e --argjson rows "$rows" 'any(.items[]; .id as $id | any($rows[]; .id == $id and .ours == "unknown"))' \
      <<<"$batch" >/dev/null; then
      fleet_capture_consume_batch=true
    fi
  elif jq -e '.confirmed == true' <<<"$batch" >/dev/null; then
    accepted=$(jq -c --argjson batch "$batch" '[.[] | select(. as $row | any($batch.items[]; . == $row))]' <<<"$staged")
    if jq -e --argjson rows "$rows" 'any(.items[]; .id as $id | any($rows[]; .id == $id and .ours == "unknown"))' \
      <<<"$batch" >/dev/null; then
      return 0
    elif [ "$(jq 'length' <<<"$accepted")" = "$(jq '.items | length' <<<"$batch")" ]; then
      staged=$accepted
      confirmed=true
      fleet_capture_consume_batch=true
    fi
  fi
  if [ "$count" -gt 0 ] && [ "$confirmed" != true ]; then
    managed=$(jq '[.[] | select(.theirs | IN("enabled","disabled","absent"))] | length' <<<"$rows")
    limits=$(jq -r '[.policy.max_changes_per_run // .policy.max_removals_per_run // 5,
      .policy.max_change_fraction // .policy.max_removal_fraction // 0.25] | @tsv' <<<"$desired")
    local per_run fraction
    IFS=$'\t' read -r per_run fraction <<<"$limits"
    cap_limit=$(fleet_removal_cap "$count" "$managed" "$per_run" "$fraction") || cap_active=true
    if [ "$discarded" = false ] && jq -e 'has("id")' <<<"$batch" >/dev/null; then pending=true; fi
    if [ "$cap_active" = true ] || [ "$pending" = true ]; then
      [ "$discarded" = false ] || return 0
      # Do not silently release a batch after the owner changes one of its items.
      staged=$(jq -c --argjson batch "$batch" --argjson rows "$rows" '
        . + [ $batch.items[]? | select(.id as $id | any($rows[]; .id == $id and .ours == "unknown")) ]
        | unique_by(.id)' <<<"$staged")
      bid=$(fleet_capture_batch_id "$staged") || return 1
      if ! jq -e --arg id "$bid" '.id == $id' <<<"$batch" >/dev/null; then
        local old_id
        old_id=$(jq -r '.id // empty' <<<"$batch")
        [ -z "$old_id" ] || fleet_alert_clear "$store" "$host" agent-capture-pending-confirm "$old_id" || :
        fleet_capture_json_write "$dir/agent-pending-confirm.json" \
          "$(jq -cn --arg id "$bid" --argjson items "$staged" '{id:$id,confirmed:false,items:$items}')" || return 1
        fleet_alert_write "$store" "$host" agent-capture-pending-confirm "$bid" \
          "$count local plugin changes need confirmation (limit $cap_limit). Use roundhouse fleet-confirm $bid or roundhouse fleet-discard $bid." || :
      fi
      return 0
    fi
  fi
  if [ "$count" -eq 0 ] && ! jq -e --argjson rows "$rows" '
    any(.items[]?; .id as $id | any($rows[]; .id == $id and .ours == "unknown"))' <<<"$batch" >/dev/null; then
    fleet_capture_consume_batch=true
  fi
  fleet_capture_items=$staged
  if [ "$staged" != '[]' ]; then
    fleet_capture_subject="user change on $host: $(jq -r 'map(.id + " " + .value) | join(", ")' <<<"$staged")"
  fi
}

fleet_capture_file_install() (
  local src=$1 dest=$2 tmp
  [ ! -L "$dest" ] && { [ ! -e "$dest" ] || [ -f "$dest" ]; } || exit 1
  tmp=$(mktemp "${dest%/*}/.roundhouse-capture.XXXXXX") || exit 1
  trap 'rm -f "$tmp"' EXIT
  cat "$src" >"$tmp" && mv -f "$tmp" "$dest"
)

fleet_capture_backup() {
  local store=$1 backup=$2 path=$3 target=$1/$3
  local save=$backup/files/$path
  [ ! -L "$target" ] && { [ ! -e "$target" ] || [ -f "$target" ]; } || return 1
  if [ -f "$target" ]; then
    mkdir -p "${save%/*}" && cp -p "$target" "$save" || return 1
  fi
  { cat "$backup/paths" && printf '%s\n' "$path"; } >"$backup/paths.next" &&
    mv -f "$backup/paths.next" "$backup/paths"
}

fleet_capture_record_staged() {
  local expected digest
  expected=$(fleet_capture_json_read "$2/expected.json" '{}') || return 1
  digest=$(sha256_file "$1") || return 1
  expected=$(jq -c --arg path "$3" --arg digest "$digest" '.[$path] = $digest' <<<"$expected") || return 1
  fleet_capture_json_write "$2/expected.json" "$expected"
}

fleet_capture_can_rollback() {
  local store=$1 backup=$2/capture-stage path expected digest physical_store parent
  [ ! -L "$backup" ] && [ ! -L "$backup/paths" ] || return 1
  [ -s "$backup/paths" ] || return 0
  expected=$(fleet_capture_json_read "$backup/expected.json" '{}') || return 1
  physical_store=$(cd "$store" && pwd -P) || return 1
  while IFS= read -r path; do
    case /$path/ in *//*|*/../*|*/./*) return 1 ;; esac
    case $path in fleet.yaml|fleet/*.yaml|os/*.yaml|groups/*.yaml|hosts/*.yaml|journal/*/*.yaml) ;; *) return 1 ;; esac
    parent=$store
    [ "${path%/*}" = "$path" ] || parent="$store/${path%/*}"
    if [ -d "$parent" ]; then
      [ "$(cd "$parent" && pwd -P)" = "$physical_store${parent#"$store"}" ] || return 1
    fi
    [ ! -L "$store/$path" ] || return 1
    if [ -f "$store/$path" ]; then
      if [ -f "$backup/files/$path" ] && cmp -s "$store/$path" "$backup/files/$path"; then continue; fi
      digest=$(sha256_file "$store/$path") || return 1
      jq -e --arg path "$path" --arg digest "$digest" '.[$path] == $digest' <<<"$expected" >/dev/null || return 1
    elif [ -e "$store/$path" ] || [ -e "$backup/files/$path" ]; then
      return 1
    fi
  done <"$backup/paths"
}

fleet_capture_stage() {
  local store=$1 backup=$2/capture-stage host=$fleet_capture_host
  local physical_store physical_dir id item harness name value market path date path_new category owner decision
  local staged_rows
  [ "$fleet_capture_items" != '[]' ] || return 0
  staged_rows=$(jq -er '.[] | [.id,.item,.harness,.name,.value,.marketplace,.path,.decision] | @tsv' \
    <<<"$fleet_capture_items") || return 1
  physical_store=$(cd "$store" && pwd -P) || return 1
  mkdir -p "$backup" && : >"$backup/paths" || return 1
  date=$(fleet_now)
  local journal
  journal=$(fleet_journal_path "$store" "$host" "$date")
  while IFS=$'\t' read -r id item harness name value market path decision; do
    case $path in
      fleet.yaml|fleet/*.yaml|os/*.yaml|groups/*.yaml) ;;
      "hosts/$host.yaml"|"hosts/$host/"*.yaml) [ "$decision" = take ] || return 1 ;;
      *) return 1 ;;
    esac
    owner=$(fleet_vcs_path_owner "$path") || return 1
    [ "$owner" = '*' ] || { [ "$decision" = take ] && [ "$owner" = "$host" ]; } || return 1
    category=${item%%.*}
    if [ "$path" = fleet/99-canonical-agents.yaml ] && [ ! -e "$store/fleet" ]; then
      mkdir "$store/fleet" || return 1
    fi
    local parent=$store
    [ "${path%/*}" = "$path" ] || parent="$store/${path%/*}"
    physical_dir=$(cd "$parent" && pwd -P) || return 1
    [ "$physical_dir" = "$physical_store${parent#"$store"}" ] || return 1
    if ! grep -Fxq -- "$path" "$backup/paths"; then
      if [ -e "$fleet_capture_layers/$path" ]; then
        cmp -s "$fleet_capture_layers/$path" "$store/$path" || return 1
      elif [ -e "$store/$path" ] || [ -L "$store/$path" ]; then
        return 1
      fi
      fleet_capture_backup "$store" "$backup" "$path" || return 1
    fi
    path_new="$backup/edited"
    local program='.[strenv(category)][strenv(name)]'
    if [ -f "$store/$path" ] &&
      category=$category name=$name yq -e "$program | tag == \"!!map\"" "$store/$path" >/dev/null; then
      if [ "$category" = plugins ]; then
        program+=' |= (.state = strenv(value) | .marketplace = (.marketplace // strenv(market)))'
      else
        program+='.state = strenv(value)'
      fi
    elif [ "$category" = plugins ]; then
      program+=' = {"state": strenv(value), "marketplace": strenv(market)}'
    else
      program+=' = {"state": strenv(value)}'
    fi
    if [ -f "$store/$path" ]; then
      category=$category name=$name value=$value market=$market \
        yq e "$program" "$store/$path" >"$path_new" || return 1
    else
      category=$category name=$name value=$value market=$market \
        yq -n "$program" >"$path_new" || return 1
    fi
    [ -s "$path_new" ] && fleet_capture_record_staged "$path_new" "$backup" "$path" &&
      fleet_capture_file_install "$path_new" "$store/$path" || return 1
    if ! grep -Fxq -- "${journal#"$store/"}" "$backup/paths"; then
      fleet_capture_backup "$store" "$backup" "${journal#"$store/"}" || return 1
    fi
    local digest
    digest=$(fleet_item_digest "$(fleet_run_desired "$store" "$host")" "$item") || return 1
    local entry
    entry=$(jq -cn --arg item "$item" --arg state "$value" --arg host "$host" \
        --arg harness "$harness" --arg at "$date" --arg digest "$digest" \
        '{item:$item,digest:$digest,state:$state,host:$host,harness:$harness,at:$at,
          outcome:"captured",who:"user"}') || return 1
    fleet_journal_entry_ok "$entry" || return 1
    fleet_record_write "$path_new" \
      "$(fleet_record_read "$journal" '[]' | jq -c --argjson e "$entry" '. + [$e]')" || return 1
    fleet_capture_record_staged "$path_new" "$backup" "${journal#"$store/"}" &&
      mkdir -p "${journal%/*}" &&
      fleet_capture_file_install "$path_new" "$journal" || return 1
  done <<<"$staged_rows"
}

fleet_capture_abort() {
  local store=$1 backup=$2/capture-stage path physical_store parent
  # An interrupted write without a recorded hash holds rather than erasing a later owner edit.
  fleet_capture_can_rollback "$1" "$2" || return 1
  [ ! -L "$backup" ] && [ ! -L "$backup/paths" ] || return 1
  [ -s "$backup/paths" ] || return 0
  physical_store=$(cd "$store" && pwd -P) || return 1
  while IFS= read -r path; do
    case /$path/ in *//*) return 1 ;; */../*|*/./*) return 1 ;; esac
    case $path in fleet.yaml|fleet/*.yaml|os/*.yaml|groups/*.yaml|hosts/*.yaml|journal/*/*.yaml) ;; *) return 1 ;; esac
    parent=$store
    [ "${path%/*}" = "$path" ] || parent="$store/${path%/*}"
    [ ! -L "$backup/files/$path" ] || return 1
    if [ -d "$parent" ]; then
      [ "$(cd "$parent" && pwd -P)" = "$physical_store${parent#"$store"}" ] || return 1
    fi
    if [ -f "$backup/files/$path" ]; then
      fleet_capture_file_install "$backup/files/$path" "$store/$path" || return 1
    else
      rm -f "$store/$path" || return 1
    fi
  done <"$backup/paths"
  rm -f "$backup/paths"
}

fleet_capture_publish_alerts() {
  local store=$1 host=$2 desired=$3 observed=$4 layers=$5 dir id rows extra baseline initialized
  local extras=()
  dir=$(fleet_instance_path store.run)
  if [ "$fleet_capture_consume_batch" = true ] && [ -e "$dir/agent-pending-confirm.json" ]; then
    id=$(fleet_capture_json_read "$dir/agent-pending-confirm.json" '{}' | jq -r '.id // empty')
    [ -z "$id" ] || fleet_alert_clear "$store" "$host" agent-capture-pending-confirm "$id" || :
  fi
  baseline=$(fleet_capture_json_read "$dir/agent-baseline.json" '{}') || return 1
  initialized=$(fleet_capture_initialized "$baseline") || return 1
  rows=$(fleet_capture_rows "$layers" "$desired" "$observed" "$baseline") || return 1
  while IFS= read -r extra; do
    [ -z "$extra" ] || extras+=("$extra")
  done < <(jq -r --argjson initialized "$initialized" '
    .[] | select($initialized[.harness] != true and .id != null and .theirs == "missing" and
      (.ours | IN("enabled","disabled"))) | .id' <<<"$rows")
  if [ "${#extras[@]}" -gt 0 ]; then
    fleet_alert_write "$store" "$host" agent-capture-ignored agent-capture-ignored \
      "Existing local plugins left in place. Use roundhouse fleet-take-local ITEM to share one." \
      "${extras[@]}" || :
  fi
}

fleet_capture_done() {
  local dir decisions updated conflicts
  dir=$(fleet_instance_path store.run)
  [ "$fleet_capture_consume_batch" != true ] ||
    rm -f "$dir/agent-pending-confirm.json" || return 1
  decisions=$(jq -c --argjson discard "$fleet_capture_discards" '
    [ .[] | select(.decision == "take") | .id,.item ] + $discard | unique' <<<"$fleet_capture_items")
  [ "$decisions" != '[]' ] || return 0
  local record
  for record in agent-take-local agent-discard agent-conflicts; do
    [ -e "$dir/$record.json" ] || continue
    conflicts=$(fleet_capture_json_read "$dir/$record.json" '{}') || return 1
    updated=$(jq -c --argjson decisions "$decisions" 'delpaths($decisions | map([.]))' <<<"$conflicts")
    if [ "$record" != agent-conflicts ] && [ "$updated" = '{}' ]; then
      rm -f "$dir/$record.json" || return 1
    elif [ "$updated" != "$conflicts" ]; then
      fleet_capture_json_write "$dir/$record.json" "$updated" || return 1
    fi
  done
}

fleet_capture_rebaseline() {
  local desired=$3 observed=$4 fetched=$5 layers=${6:-$1}
  local dir baseline initialized rows updated id fallback
  [ "$fetched" = true ] || return 0
  dir=$(fleet_instance_path store.run)
  baseline=$(fleet_capture_json_read "$dir/agent-baseline.json" '{}') || return 1
  initialized=$(fleet_capture_initialized "$baseline") || return 1
  rows=$(fleet_capture_rows "$layers" "$desired" "$observed" "$baseline") || return 1
  # A first pass with no usable harness must still get a silent observation.
  if jq -e '.claude == null and .codex == null' <<<"$observed" >/dev/null; then
    return 0
  fi
  updated=$(jq -c --argjson base "$baseline" --argjson discard "${fleet_capture_discards:-[]}" \
    --argjson initialized "$initialized" --argjson observed "$observed" "$fleet_capture_authority_filter"'
    . as $rows |
    reduce (.[] | select(.ours | IN("enabled","disabled","absent"))) as $r ($base;
      if $r.ours == $r.theirs then
        .[$r.id // $r.item] = {value:$r.theirs} |
        if $r.id != null then del(.[$r.item]) else . end
      elif $r.id == null or $r.theirs != "missing" then .
      elif $r.ours != "absent" and
        ($initialized[$r.harness] != true or $r.base != null or ($discard | index($r.id)) != null) then
        .[$r.id] = {value:$r.ours,ignored:true}
      elif $r.base.ignored then del(.[$r.id])
      elif $r.base != null then .[$r.id] = {value:$r.ours,ignored:true}
      else . end) |
    ._initialized = (reduce ["claude","codex"][] as $h ($initialized;
      if authoritative($observed; $base; $h) and all($rows[] | select(.harness == $h);
        .ours != "unknown" or .ambiguous == true or
        (.id != null and $observed[$h][.id | ltrimstr($h + ":")].user_scope == false))
      then .[$h] = true else . end))' <<<"$rows") || return 1
  if [ "$updated" != "$baseline" ]; then
    fleet_capture_json_write "$dir/agent-baseline.json" "$updated" || return 1
  fi
  while IFS= read -r id; do
    local marker
    marker=$(fleet_agent_pending_path "$id") || continue
    rm -f "$marker" || return 1
    case $id in
      claude:*) fallback=$(fleet_agent_pending_path "${id%@*}@__unqualified__") || continue
        rm -f "$fallback" || return 1 ;;
    esac
  done < <(jq -r --argjson updated "$updated" '.[] |
    select(.id != null and (.ours | IN("enabled","disabled","absent")) and
      ((.ours == .theirs and $updated[.id] == {value:.theirs}) or
       (.theirs == "missing" and
        (.base == null or $updated[.id] == null or .base == {value:.ours,ignored:true})))) |
    .id' <<<"$rows")
}
