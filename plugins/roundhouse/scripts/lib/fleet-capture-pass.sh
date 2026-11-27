# roundhouse — capture integration, separate from the pure merge and policy.
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
      if $harness == "codex" then has("codex_plugins." + $id)
      else has("plugins." + $name) or has("plugins." + $id) end' >/dev/null
}

fleet_capture_state_matches() {
  local item=$1 value=$2 observed=$3 defs=$4 market name
  case $item in
    codex_plugins.*)
      printf '%s\n' "$observed" | jq -e --arg id "${item#codex_plugins.}" \
        --arg state "$(fleet_run_state_of "$value")" \
        '.codex != null and ((.codex[$id].value // "absent") == $state)' >/dev/null
      return
      ;;
  esac
  name=${item#plugins.}
  case $name in
    *@*) ;;
    *)
      market=$(fleet_run_plugin_market "$defs" "$name" "$value") || return 1
      if [ -n "$market" ]; then
        name=$name@$market
      else
        name=$(printf '%s\n' "$observed" | jq -er --arg name "$name" \
          '[.claude // {} | keys[] | select(split("@")[0] == $name)] |
          if length == 1 then .[0] else empty end') || return 1
      fi
      ;;
  esac
  printf '%s\n' "$observed" | jq -e --arg id "$name" \
    --arg state "$(fleet_run_state_of "$value")" '
      .claude != null and ((.claude[$id].value // "absent") == $state)' >/dev/null
}

fleet_capture_fingerprint() {
  # Raw record hashes only wake a pass; versions and unrelated settings never
  # enter the merge. Missing/unreadable records wake it too, to report unknown.
  for capture_fp in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/installed_plugins.json" \
    "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" \
    "${CODEX_HOME:-$HOME/.codex}/config.toml"; do
    if [ -f "$capture_fp" ] && [ -r "$capture_fp" ]; then
      sha256_file "$capture_fp" || return 1
    else
      printf 'missing\n'
    fi
  done | sha256_stream
}

fleet_capture_dirty() {
  capture_dirty_dir=$(fleet_run_state_dir)
  [ -f "$capture_dirty_dir/agent-baseline.json" ] || return 0
  for capture_decision in agent-take-local agent-discard; do
    if [ -e "$capture_dirty_dir/$capture_decision.json" ]; then
      jq -e 'length == 0' "$capture_dirty_dir/$capture_decision.json" >/dev/null 2>&1 || return 0
    fi
  done
  if [ -e "$capture_dirty_dir/agent-pending-confirm.json" ]; then
    ! jq -e '.confirmed == true or .discarded == true' \
      "$capture_dirty_dir/agent-pending-confirm.json" >/dev/null 2>&1 || return 0
  fi
  capture_fp_now=$(fleet_capture_fingerprint) || return 0
  [ "$capture_fp_now" != "$(cat "$capture_dirty_dir/agent-fingerprint" 2>/dev/null)" ]
}

fleet_capture_pass_prepare() {
  # STORE HOST DESIRED CLEAN FETCHED TMP LAYERS
  fleet_capture_before_fingerprint=$(fleet_capture_fingerprint) || fleet_capture_before_fingerprint=
  fleet_capture_observed=$(fleet_capture_collect "$6/capture-before") ||
    fleet_capture_observed='{"claude":null,"codex":null,"retry":true}'
  fleet_capture_prepare "$1" "$2" "$3" "$fleet_capture_observed" "$4" "$5" "$6" "$7" || return $?
  printf '%s\n' "$fleet_capture_skip" | jq -r 'keys[]' >"$6/capture-skip"
}

fleet_capture_revalidate() {
  local baseline before after
  baseline=$(fleet_capture_json_read "$(fleet_run_state_dir)/agent-baseline.json" '{}') || return 2
  before=$(fleet_capture_rows "$1" "$2" "$fleet_capture_before_observed" "$baseline") || return 2
  after=$(fleet_capture_rows "$1" "$2" "$3" "$baseline") || return 2
  jq -e --argjson items "$fleet_capture_items" --argjson before "$before" \
    --argjson old "$fleet_capture_before_observed" --argjson new "$3" '
    . as $after | all($items[]; . as $item |
      if .decision == "mirror" then
        $old.codex != null and $new.codex != null and $new.codex_markets[.marketplace] == true and
          $old.codex[.name] == $new.codex[.name]
      else
        any($after[]; .id == $item.id and .item == $item.item and .stageable and
          (.ours | IN("enabled","disabled","absent")) and
          (.ours as $ours | any($before[]; .id == $item.id and .item == $item.item and .ours == $ours)))
      end)' >/dev/null <<<"$after"
}

fleet_capture_transaction_path() {
  fleet_instance_path store.run/agent-capture-transaction
}

fleet_capture_transaction_basis() {
  # Snapshotting @ can change its ID while a stage is live. Its parents and
  # main must still be unchanged for a file-only rollback to be sufficient.
  jj --ignore-working-copy -R "$1" log -r '@- | heads(bookmarks(exact:"main"))' \
    --no-graph -T 'commit_id ++ "\n"'
}

fleet_capture_transaction_hold() {
  printf 'roundhouse: interrupted plugin capture at %s; publication held until its staged changes and remote outcome are checked\n' "$2" >&2
  fleet_alert_write "$1" "$(fleet_host_name)" agent-capture-interrupted agent-capture-interrupted \
    'Plugin capture was interrupted. Publication is held until its staged changes and remote outcome are checked.' || :
  return 75
}

fleet_capture_transaction_remove() {
  # Keep the publishing marker until no backups can be replayed.
  rm -rf "$1/capture-stage" && rm -f "$1/basis" "$1/publishing" && rmdir "$1"
}

fleet_capture_transaction_target() {
  [ -n "${fleet_capture_active_txn:-}" ] || return 0
  local state
  state=$(fleet_capture_json_read "$fleet_capture_active_txn/publishing" '{}') || return 1
  state=$(jq -c --arg target "$1" '.target = $target | .phase = "publishing"' <<<"$state") || return 1
  fleet_capture_json_write "$fleet_capture_active_txn/publishing" "$state"
}

fleet_capture_transaction_resolve() (
  local store=$1 transaction=$2 state target operation remote scratch holds observed desired host
  state=$(fleet_capture_json_read "$transaction/publishing" '{}') || exit 1
  operation=$(jq -er '.operation | select(test("^[0-9a-f]+$"))' <<<"$state") || exit 1
  target=$(jq -er '.target // "" | select(. == "" or test("^[0-9a-f]{40,64}$"))' <<<"$state") || exit 1
  host=$(fleet_host_name) || exit 1
  # A cached remote ref cannot settle an interrupted push.
  fleet_vcs_fetch "$store" origin >/dev/null 2>&1 || exit 1
  remote=$(fleet_vcs_head_origin "$store") || exit 1
  [ -n "$remote" ] || exit 1
  holds=$(fleet_trust_catch_up "$store" "$remote") && [ -z "$holds" ] || exit 1
  local reviewed
  reviewed=$(fleet_trust_reviewed_ref) || exit 1
  if [ -n "$reviewed" ]; then
    [ -n "$(jj -R "$store" log -r "$reviewed & ::$remote" --no-graph -T commit_id)" ] || exit 1
  fi
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-capture-recover.XXXXXX") || exit 1
  trap 'rm -rf "$scratch"' EXIT
  fleet_run_export "$store" "$remote" "$scratch/layers" || exit 1
  fleet_vcs_enrolled_hosts "$store" "$remote" >"$scratch/hosts" || exit 1
  fleet_trust_roster_at_head "$store" "$remote" "$scratch/roster" || exit 1
  holds=$(fleet_run_signature_holds "$store" "::$remote" "$scratch/hosts" \
    "$scratch/layers" "$host" "$scratch/roster" "$scratch/verify") && [ -z "$holds" ] || exit 1
  if [ -n "$target" ]; then
    holds=$(jj -R "$store" log -r "$target & ::$remote" --no-graph -T commit_id) || exit 1
  else
    holds=
  fi
  if [ -n "$holds" ]; then
    observed=$(fleet_capture_collect "$scratch/observed") || exit 1
    desired=$(fleet_run_desired "$scratch/layers" "$host") || exit 1
    fleet_capture_items=$(jq -c '.items' <<<"$state") || exit 1
    fleet_capture_discards=$(jq -c '.discards' <<<"$state") || exit 1
    fleet_capture_consume_batch=$(jq -r '.consume_batch' <<<"$state") || exit 1
    fleet_capture_rebaseline "$store" "$host" "$desired" "$observed" true "$scratch/layers" &&
      fleet_capture_verified_discards "$(fleet_run_state_dir)" "$scratch/layers" "$desired" "$observed" &&
      fleet_capture_done || exit 1
  else
    fleet_capture_abort "$store" "$transaction" || exit 1
    # Restore the graph without overwriting unrelated owner saves or undoing fetch.
    jj --ignore-working-copy -R "$store" op restore "$operation" --what repo >/dev/null || exit 1
  fi
  fleet_capture_transaction_remove "$transaction" || exit 1
  fleet_alert_clear "$store" "$host" agent-capture-interrupted agent-capture-interrupted
)

fleet_capture_transaction_recover() {
  local transaction basis current
  transaction=$(fleet_capture_transaction_path) || return 65
  [ -e "$transaction" ] || [ -L "$transaction" ] || return 0
  if [ -L "$transaction" ] || [ ! -d "$transaction" ] || [ -L "$transaction/publishing" ]; then
    [ "${2:-}" = staging-only ] || fleet_capture_transaction_hold "$1" "$transaction"
    return
  fi
  if [ -e "$transaction/publishing" ]; then
    [ "${2:-}" != staging-only ] || return 0
    fleet_capture_transaction_resolve "$1" "$transaction" || fleet_capture_transaction_hold "$1" "$transaction"
    return
  fi
  if [ -s "$transaction/capture-stage/paths" ]; then
    if [ -L "$transaction/basis" ] || ! basis=$(cat "$transaction/basis") ||
      ! current=$(fleet_capture_transaction_basis "$1") || [ -z "$basis" ] || [ "$basis" != "$current" ]; then
      fleet_capture_transaction_hold "$1" "$transaction"
      return
    fi
  fi
  fleet_capture_abort "$1" "$transaction" && fleet_capture_transaction_remove "$transaction" ||
    fleet_capture_transaction_hold "$1" "$transaction"
}

fleet_capture_verified_discards() {
  local baseline rows batch row_baseline
  local dir=$1
  [ "$fleet_capture_discards" != '[]' ] || [ "$fleet_capture_consume_batch" = true ] || return 0
  baseline=$(fleet_capture_json_read "$dir/agent-baseline.json" '{}') || return 1
  batch=$(fleet_capture_json_read "$dir/agent-pending-confirm.json" '{}') || return 1
  if jq -e '.discarded == true' >/dev/null <<<"$batch"; then
    fleet_capture_discards=$(jq -c --argjson discard "$fleet_capture_discards" \
      '$discard + [.items[] | select(.decision != "mirror") | .id] | unique' <<<"$batch") || return 1
  fi
  row_baseline=$(jq -cn --argjson base "$baseline" --argjson batch "$batch" '
    (if $batch.discarded == true then reduce $batch.items[] as $i ({};
      .[$i.id] = {value:$i.value,ignored:true}) else {} end) + $base') || return 1
  rows=$(fleet_capture_rows "$2" "$3" "$4" "$row_baseline") || return 1
  fleet_capture_discards=$(jq -c --argjson base "$baseline" --argjson discard "$fleet_capture_discards" '
    [.[] | . as $r | select(.id != null and ($discard | index($r.id)) != null) |
      select(if .theirs == "missing" then $base[.id] == {value:.ours,ignored:true} or
          (.ours == "absent" and $base[.id] == null)
        else .ours == .theirs and $base[.id] == {value:.theirs} end) | .id,.item] | unique' <<<"$rows") || return 1
  if jq -e --argjson verified "$fleet_capture_discards" '
    .discarded == true and any(.items[]; .decision != "mirror" and (.id as $id | $verified | index($id) == null))
    ' >/dev/null <<<"$batch"; then
    fleet_capture_consume_batch=false
  fi
}

fleet_capture_pass_publish() {
  # STORE HOST TMP DESIRED LAYERS INTENT ITEMS
  # Publish replicated alerts with the pass. Advance host-local agreement
  # only once that publication succeeds.
  local capture_after capture_after_fingerprint capture_publish_op capture_publish_rc=0
  local capture_publish_mode= capture_published_layers=$1 capture_published_desired dir
  local fleet_capture_active_txn= fleet_vcs_push_uncertain=false fleet_vcs_pushed_target=
  dir=$(fleet_run_state_dir) || return 65
  fleet_run_cli_invalidate
  capture_after_fingerprint=$(fleet_capture_fingerprint) || capture_after_fingerprint=
  capture_after=$(fleet_capture_collect "$3/capture-after") ||
    capture_after='{"claude":null,"codex":null,"retry":true}'
  if [ "${fleet_capture_retry_unknown:-false}" = true ] ||
    ! jq -e --argjson after "$capture_after" '. == $after and .retry != true' \
      >/dev/null <<<"$fleet_capture_before_observed"; then
    : >"$dir/retry-owed" || return 65
    capture_after_fingerprint=${fleet_capture_before_fingerprint:-}
  fi
  if [ "$fleet_capture_items" != '[]' ] && ! fleet_capture_revalidate "$5" "$4" "$capture_after"; then
    printf 'roundhouse: plugin state changed or became unknown during the pass; holding the capture batch\n' >&2
    fleet_capture_items='[]'
    fleet_capture_subject=
    fleet_capture_consume_batch=false
    : >"$dir/retry-owed" || return 65
  fi
  fleet_capture_publish_alerts "$1" "$2" "$4" "$capture_after" "$5" || return $?
  if [ "$fleet_capture_items" != '[]' ]; then
    capture_publish_op=$(fleet_vcs_op_id "$1") || return 65
    fleet_capture_active_txn=$(fleet_capture_transaction_path) || return 65
    mkdir "$fleet_capture_active_txn" || return 65
    fleet_capture_transaction_basis "$1" >"$fleet_capture_active_txn/basis" || return 65
    fleet_capture_stage "$1" "$fleet_capture_active_txn" || {
      fleet_capture_transaction_recover "$1" || return $?
      return 65
    }
    # From describe/bookmark movement onward a crash may leave a commit.
    fleet_capture_json_write "$fleet_capture_active_txn/publishing" \
      "$(jq -cn --arg operation "$capture_publish_op" --argjson items "$fleet_capture_items" \
        --argjson discards "$fleet_capture_discards" --argjson consume "$fleet_capture_consume_batch" \
        '{phase:"staged",operation:$operation,items:$items,discards:$discards,consume_batch:$consume}')" || return 65
    capture_publish_mode=no-recover
  fi
  fleet_run_publish "$1" "$2" scheduled/agent "$6" \
    "$7 $(printf '%s\n' "$fleet_capture_items" | jq -r '.[].item' | tr '\n' ' ')" \
    "${fleet_capture_subject:-converge on $2}" "$capture_publish_mode" || capture_publish_rc=$?
  if [ -z "$fleet_vcs_pushed_target" ]; then
    if [ -n "$fleet_capture_active_txn" ]; then
      [ "$fleet_vcs_push_uncertain" != true ] || { fleet_capture_transaction_hold "$1" "$fleet_capture_active_txn"; return 75; }
      fleet_capture_abort "$1" "$fleet_capture_active_txn" &&
        fleet_vcs_op_restore "$1" "$capture_publish_op" &&
        fleet_capture_transaction_remove "$fleet_capture_active_txn" || return 65
    fi
    return "$capture_publish_rc"
  fi
  if [ -n "$fleet_capture_active_txn" ] || [ "$capture_publish_rc" -ne 0 ]; then
    capture_published_layers=$3/capture-published
    fleet_run_export "$1" "$fleet_vcs_pushed_target" "$capture_published_layers" || return 65
  fi
  capture_published_desired=$(fleet_run_desired "$capture_published_layers" "$2") || return 65
  fleet_capture_rebaseline "$1" "$2" "$capture_published_desired" "$capture_after" true "$capture_published_layers" || return $?
  fleet_capture_verified_discards "$dir" "$capture_published_layers" "$capture_published_desired" "$capture_after" || return 65
  fleet_capture_done || return $?
  [ -z "$fleet_capture_active_txn" ] || fleet_capture_transaction_remove "$fleet_capture_active_txn" || return 65
  printf '%s\n' "$capture_after_fingerprint" >"$dir/agent-fingerprint" || return 65
  return "$capture_publish_rc"
}
