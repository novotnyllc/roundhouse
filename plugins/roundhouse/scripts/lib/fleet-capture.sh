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

fleet_agent_journal_path() {
  local id=$1
  fleet_capture_id_valid "$id" || return 1
  case $id in *@__unqualified__) return 1 ;; esac
  if [ "${#id}" -gt 200 ]; then
    id=$(printf '%s' "$id" | sha256_stream) || return 1
  fi
  fleet_instance_path "store.run/agent-journal/${id/:/.}"
}

fleet_capture_home() {
  local dir=${CLAUDE_CONFIG_DIR:-$HOME/.claude} suffix=
  # A first install may not have created its home yet.
  case $dir in /*) ;; *) dir=$PWD/$dir ;; esac
  while [ ! -d "$dir" ]; do
    [ ! -L "$dir" ] || return 1
    case ${dir##*/} in .|..) return 1 ;; esac
    suffix=/${dir##*/}$suffix
    dir=${dir%/*}
    [ -n "$dir" ] || dir=/
  done
  dir=$(CDPATH='' cd -P -- "$dir" && pwd -P) || return 1
  if [ "$dir" = / ] && [ -z "$suffix" ]; then printf '/\n'
  else printf '%s%s\n' "${dir%/}" "$suffix"; fi
}

fleet_agent_journal_read() {
  local path record home
  path=$(fleet_agent_journal_path "$1") || return 1
  home=$(fleet_capture_home) || return 1
  record=$(fleet_capture_json_read "$path" '{}') || return 1
  jq -ce --arg id "$1" --arg home "$home" '
    if . == {} then {id:$id,home:$home}
    elif .id == $id then . else error("journal identity mismatch") end' <<<"$record"
}

fleet_capture_next_seq() {
  # All mutating entrypoints hold the instance run lock.
  local path seq
  path=$(fleet_instance_path store.run/agent-seq)
  seq=$(fleet_capture_json_read "$path" '{"seq":0}') || return 1
  seq=$(jq -er '.seq | if type == "number" and . >= 0 and floor == . then . + 1
    else error("invalid sequence") end' <<<"$seq") || return 1
  fleet_capture_json_write "$path" "{\"seq\":$seq}" || return 1
  printf '%s\n' "$seq"
}

fleet_agent_journal_unresolved() {
  local home
  home=$(fleet_capture_home) || return 0
  jq -e --arg home "$home" --arg active "${fleet_capture_active_op:-}" '
    .home != $home or (.intent != null and
      (.intent.op_id != $active or $active == ""))' >/dev/null <<<"$1"
}

fleet_agent_receipt_matches() {
  jq -e --arg state "$2" '
    .receipt as $r | $r != null and
    (if $state == "absent" then $r.installed == false
     elif $state | IN("enabled","disabled") then
       $r.installed == true and $r.state == $state
     else false end)' >/dev/null <<<"$1"
}

fleet_capture_journal_clear() {
  local path
  path=$(fleet_agent_journal_path "$1") || return 1
  rm -f "$path"
}

fleet_capture_quarantine_path() {
  local key
  key=$(printf '%s' "$1" | sha256_stream) || return 1
  fleet_instance_path "store.run/agent-quarantine/$key"
}

fleet_capture_quarantined() {
  local path
  path=$(fleet_capture_quarantine_path "$1") || return 0
  [ -e "$path" ]
}

fleet_capture_name_unique() {
  jq -e --arg name "$1" '[.[] | select(.id != null) | .id |
    select((ltrimstr("claude:") | split("@")[0]) == $name)] | unique | length == 1' \
    >/dev/null <<<"$2"
}

fleet_capture_migrate_pending() {
  local dir path id journal home record seq name
  dir=$(fleet_instance_path store.run)
  for path in "$dir"/agent-pending/*; do
    [ -f "$path" ] && [ ! -L "$path" ] || continue
    record=$(fleet_capture_json_read "$path" '{}') || record='{}'
    id=$(jq -r '.id // empty' <<<"$record") || id=
    if ! fleet_capture_id_valid "$id"; then
      # A damaged marker still has its physical filename; never infer a marketplace.
      id=${path##*/}
      id=${id/claude./claude:}
    fi
    fleet_capture_id_valid "$id" || continue
    case $id in
      *@__unqualified__)
        # Old bare-name intent cannot establish which marketplace was mutated.
        name=${id#claude:}; name=${name%@*}
        journal=$(fleet_capture_quarantine_path "$name") || return 1
        record=$(jq -cn --arg name "$name" --argjson old "$record" \
          '{name:$name,intent:$old}') || return 1
        fleet_capture_json_write "$journal" "$record" || return 1
        rm -f "$path" || return 1
        continue ;;
    esac
    journal=$(fleet_agent_journal_path "$id") || return 1
    home=$(fleet_capture_home) || return 1
    seq=$(fleet_capture_next_seq) || return 1
    # Even a pre-existing receipt cannot resolve an older ambiguous intent.
    record=$(fleet_agent_journal_read "$id") || return 1
    record=$(jq -c --argjson seq "$seq" '.intent = {op:"legacy",to:null,
      from:null,op_id:"legacy-unresolved",pid:0,start:"",seq:$seq}' <<<"$record") || return 1
    fleet_capture_json_write "$journal" "$record" || return 1
    rm -f "$path" || return 1
  done
}

fleet_capture_pending_ids() (
  local dir path id
  dir=$(fleet_instance_path store.run)
  for path in "$dir"/agent-journal/*; do
    [ -f "$path" ] && [ ! -L "$path" ] || continue
    id=$(jq -er '.id | strings' "$path") || continue
    [ "$path" = "$(fleet_agent_journal_path "$id")" ] || continue
    printf '%s\n' "$id"
  done
)

fleet_capture_listing_filter='
  def id_ok: type == "string" and test("^[A-Za-z0-9_-][A-Za-z0-9._-]*@[A-Za-z0-9_-][A-Za-z0-9._-]*$");
  def known_scope: IN("user","project","local","managed");
  def claude_manager: [.[] | select(.kind == "plugin_manager" and .data.agent == "claude")];
  def claude_plugins:
    [.[] | select(.kind == "plugin" and .data.agent == "claude" and .data.inventory_source == "manager")];
  def listing:
    claude_manager as $manager |
    claude_plugins as $rows |
    if ($manager | length) == 1 and $manager[0].status == "present" and
      $manager[0].data.authoritative == true and $manager[0].data.installed_count == ($rows | length) and
      all($rows[]; .status == "present" and (.data.manager_id | id_ok) and
        (.data.enabled | type) == "boolean" and
        .data.manager_id == (.data.name + "@" + .data.marketplace))
    then {
      items:([$rows[].data | select(.scope == "user" or (.scope | known_scope | not))] |
        group_by(.manager_id) | map({
          key:.[0].manager_id,
          value:(if length == 1 and .[0].scope == "user" then .[0] else {uncertain:true} end)
        }) | from_entries),
      users:([$rows[].data | select(.scope == "user")] |
        group_by(.manager_id) | map({key:.[0].manager_id,value:map(.enabled)}) | from_entries)
    }
    else null end;'

fleet_capture_claude_observe() {
  local listing=$1 records installed_path
  installed_path="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/installed_plugins.json"
  records=$(fleet_capture_guard_records) || return 1
  if [ -e "$installed_path" ]; then
    jq -es 'length == 1 and (.[0].plugins | type) == "object"' "$installed_path" >/dev/null || return 1
  fi
  local missing id path
  missing=$(jq -rc --argjson listing "$listing" "$fleet_capture_listing_filter"'
    .enabled as $enabled | .registry |
    to_entries[] | .key as $id | select($listing[$id] == null and all(.value[]; .scope | known_scope)) |
    .value[] | select(.scope == "user") |
    [$id, ($enabled[$id] | type), (.installPath // "")] | @tsv' <<<"$records") || return 1
  local known_state
  while IFS=$'\t' read -r id known_state path; do
    [ -n "$id" ] || continue
    # A missing CLI row is admissible only for a damaged install with an
    # intact user record and explicit enabled state.
    [ "$known_state" = boolean ] && [ -n "$path" ] && [ ! -e "$path" ] || return 1
  done <<<"$missing"
  jq -c --argjson listing "$listing" "$fleet_capture_listing_filter"'
    . as $raw | .registry as $installed | .enabled as $enabled |
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
      {claude:(($enabled | with_entries(select(.key | id_ok) | .value = {value:"unknown"})) + $records +
        ($listing | with_entries(select(.value.uncertain) | .value = {value:"unknown",user_scope:null}))),
        records:$raw}
    end' <<<"$records"
}

fleet_capture_observe() {
  local lists listing reconciliation=null
  lists=$(jq -cs "$fleet_capture_listing_filter"'
    {listing:listing, inapplicable:((claude_manager | length == 1 and .[0].status == "absent") and
      (claude_plugins | length == 0))}' "$1") || return 1
  listing=$(jq -c '.listing.items' <<<"$lists") || return 1
  if [ "$listing" != null ]; then
    reconciliation=$(fleet_capture_claude_observe "$listing" 2>/dev/null) || reconciliation=null
  fi
  printf '%s\n' "$lists" "$reconciliation" | jq -cs '
    .[0] as $list | .[1] as $scan |
    {claude:$scan.claude,records:$scan.records,users:$list.listing.users,
      inapplicable:$list.inapplicable,retry:($scan == null and ($list.inapplicable | not))}'
}

fleet_capture_empty_agrees() {
  local baseline records id journal capture_home
  baseline=$(fleet_capture_json_read "$(fleet_instance_path store.run/agent-baseline.json)" '{}') || return 1
  capture_home=$(fleet_capture_home) || return 1
  records=$(while IFS= read -r id; do
    [ -n "$id" ] || continue
    journal=$(fleet_agent_journal_read "$id") || continue
    jq -c --arg base_home "$capture_home" '
      select(.home == $base_home and (.receipt.seq | type == "number" and . > 0 and floor == .) and
        (.receipt.installed | type) == "boolean") |
      {key:.id,value:.receipt}' <<<"$journal"
  done < <(fleet_capture_pending_ids) | jq -cs from_entries) || return 1
  jq -e --argjson receipts "$records" '
    . as $base | all((keys + ($receipts | keys)) | unique[] | select(startswith("claude:"));
      . as $id | $base[$id] as $agreed | $receipts[$id] as $receipt |
      if $receipt != null and $receipt.seq > ($agreed.seq // 0) then $receipt.installed == false
      else ($agreed.value | IN("enabled","disabled") | not) end)' >/dev/null <<<"$baseline"
}

fleet_capture_collect() {
  local snapshot=$1/agents.jsonl rc=0 before after observed trusted=false
  mkdir -p "$1" || return 1
  before=$(fleet_capture_guard_records) || before=null
  if fleet_test_hook "${ROUNDHOUSE_SEED_SNAPSHOT:-}"; then
    cp "$ROUNDHOUSE_SEED_SNAPSHOT" "$snapshot" || return 1
  else
    set -- --section agents --output "$snapshot"
    [ -z "${fleet_capture_target:-}" ] || set -- "$@" --target "$fleet_capture_target"
    [ "${fleet_capture_native_target:-false}" != true ] || set -- "$@" --native-target
    collect_command "$@" >/dev/null || rc=$?
  fi
  observed='{"claude":null,"inapplicable":false}'
  case $rc in
    0|2) if [ -s "$snapshot" ]; then
      observed=$(fleet_capture_observe "$snapshot") || observed='{"claude":null,"inapplicable":false}'
    fi ;;
  esac
  after=$(fleet_capture_guard_records) || after=null
  if printf '%s\n' "$observed" "$before" "$after" | jq -se "$fleet_capture_listing_filter"'
    def evidence:
      {scopes:(.registry | objects | with_entries(
        .value |= (map(.scope | select(. == "user" or (known_scope | not))) | sort) |
        select(.value | length > 0))), enabled, registry_present, settings_present};
    .[1] as $before | .[2] as $after | .[0] | select(.claude != null) |
    ($before | evidence) as $guard |
    $guard == ($after | evidence) and $guard == (.records | evidence) and
    ([$guard.scopes | to_entries[] | select(.value | index("user") != null) | .key] | sort) == (.users | keys) and
    all(.users | to_entries[]; $guard.enabled[.key] as $enabled |
      $enabled == null or (.value | length != 1 or .[0] == $enabled))' >/dev/null 2>&1 &&
    { jq -e 'any(.claude[]; .value | IN("enabled","disabled"))' >/dev/null <<<"$observed" ||
      fleet_capture_empty_agrees; }; then
    trusted=true
  fi
  jq -c --argjson trusted "$trusted" '
    {claude,inapplicable,trusted:$trusted,retry:($trusted == false and (.inapplicable | not))}' <<<"$observed"
}

fleet_capture_authority_filter='def authoritative($observed): $observed.trusted == true;'

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
      (authoritative($observed) | not) as $unknown |
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
          ours:(if $unknown then "unobserved"
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
          ours:(if $unknown then "unobserved"
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
      if $duplicate or .ambiguous == true then
        .ambiguous = true | if .ours == "unobserved" then . else .ours = "unknown" end
      else . end)'
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
  jq -e '.trusted == true' >/dev/null <<<"$observed" || return 0
  dir=$(fleet_instance_path store.run)
  baseline=$(fleet_capture_json_read "$dir/agent-baseline.json" '{}') || return 1
  initialized=$(fleet_capture_initialized "$baseline") || return 1
  rows=$(fleet_capture_rows "$layers" "$desired" "$observed" "$baseline") || return 1
  updated=$(jq -c --argjson base "$baseline" --argjson discard "${fleet_capture_discards:-[]}" \
    --argjson initialized "$initialized" '
    reduce (.[] | select(.theirs != "malformed" and (.ours | IN("enabled","disabled","absent")))) as $r ($base;
      if $r.ours == $r.theirs then
        .[$r.id // $r.item] = {value:$r.theirs} |
        if $r.id != null then del(.[$r.item]) else . end
      elif ($r.base.raced? // false) == true and ($discard | index($r.id)) == null then .
      elif $r.id != null and $r.theirs != "missing" and $r.base == null and
        $initialized[$r.harness] != true then
        # First-pass disagreements with an installed plugin stay held after initialization.
        .[$r.id] = {value:(if $r.ours != "absent" and $r.id != "claude:roundhouse@novotnyllc"
          then $r.theirs else $r.ours end)}
      elif $r.id == null or $r.theirs != "missing" then .
      elif $r.ours != "absent" and
        ($initialized[$r.harness] != true or $r.base != null or ($discard | index($r.id)) != null) then
        .[$r.id] = {value:$r.ours,ignored:true}
      elif ($r.base | objects | .ignored) // false then del(.[$r.id])
      elif $r.base != null then .[$r.id] = {value:$r.ours,ignored:true}
      else . end) |
    ._initialized = ($initialized | .claude = true)' <<<"$rows") || return 1
  if [ "$updated" != "$baseline" ]; then
    fleet_capture_json_write "$dir/agent-baseline.json" "$updated" || return 1
  fi
  settled=$(jq -r --argjson updated "$updated" '
    .[] | select(.id != null) |
    select((.ours == .theirs and $updated[.id] == {value:.theirs}) or
      (.theirs == "missing" and (.base == null or $updated[.id] == null or
        .base == {value:.ours,ignored:true}))) | .id' <<<"$rows") || return 1
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    # An interrupted verb settles only on trusted store agreement or discard.
    local journal
    journal=$(fleet_agent_journal_read "$id") || return 1
    if fleet_agent_journal_unresolved "$journal" &&
      ! jq -e --arg id "$id" 'any(.[]; .id == $id and .ours == .theirs)' >/dev/null <<<"$rows"; then
      continue
    fi
    fleet_capture_journal_clear "$id" || return 1
    if jq -e --arg id "$id" 'any(.[]; .id == $id and .ours == .theirs)' >/dev/null <<<"$rows"; then
      local quarantine name
      name=${id#claude:}; name=${name%@*}
      if fleet_capture_name_unique "$name" "$rows"; then
        quarantine=$(fleet_capture_quarantine_path "$name") || return 1
        rm -f "$quarantine" || return 1
      fi
    fi
  done <<<"$settled"
}
