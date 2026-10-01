# roundhouse — the supervised verbs that PUBLISH: fleet-compact-alerts and
# fleet-disown.
#
# Every other supervised verb writes into the working copy and stops (the
# block above fleet_review_command in lib/fleet-run.sh says why). These two
# exist only to change replicated records, so each takes the run lock, refuses
# a diverged main or a working copy carrying anything but this host's own
# records (fleet_run_verb_begin), and commits through the same publish path the
# run uses.
#
# Sourced by scripts/roundhouse; carries definitions only.
# shellcheck shell=bash

fleet_run_wc_foreign_paths() {
  # fleet_run_wc_foreign_paths STORE HOST — the paths @ changes that are NOT
  # HOST's own records (journal/<h>/, alerts/<h>/, findings/<h>/,
  # applied/<h>.yaml, upstreams/<id>/<h>.yaml), one per line; silence when @
  # is clean or carries only those. Exit 65 when @ cannot be read. Which paths
  # are a host's own is fleet_vcs_path_owner's table, through its one-pass
  # form fleet_vcs_host_record_filter.
  fleet_run_wc_names=$(cd "$1" && jj diff -r @ --name-only 2>/dev/null) || return 65
  printf '%s\n' "$fleet_run_wc_names" | fleet_vcs_host_record_filter "$2"
}

fleet_run_verb_begin() {
  # fleet_run_verb_begin STORE HOST VERB — the preamble of a supervised verb
  # that PUBLISHES rather than leaving its write for the next run: the store
  # is this fleet's, main is one head, the run lock is this verb's, and @
  # carries nothing but this host's own records — so the commit it publishes
  # says what the verb did and nothing an operator was still editing. Sets
  # `fleet_run_verb_nonce` for the caller's release trap.
  fleet_vcs_store_ready "$1" || return $?
  [ "$(fleet_vcs_heads_local "$1" | grep -c .)" -eq 1 ] || {
    printf 'roundhouse: main is diverged; reconcile before %s (§8.2)\n' "$3" >&2
    return 65
  }
  fleet_run_verb_rc=0
  fleet_run_lock_take "$1" "$2" "$(fleet_lock_path)" || fleet_run_verb_rc=$?
  case $fleet_run_verb_rc in
    0) ;;
    10)
      printf 'roundhouse: a run holds %s; %s waits for it — retry when it finishes\n' \
        "$(fleet_lock_path)" "$3" >&2
      return 75
      ;;
    *) return "$fleet_run_verb_rc" ;;
  esac
  fleet_run_verb_nonce=$fleet_lock_nonce_held
  fleet_run_verb_foreign=$(fleet_run_wc_foreign_paths "$1" "$2") || {
    fleet_lock_release "$(fleet_lock_path)" "$fleet_run_verb_nonce"
    printf 'roundhouse: could not read the working copy; %s refused\n' "$3" >&2
    return 65
  }
  [ -z "$fleet_run_verb_foreign" ] || {
    fleet_lock_release "$(fleet_lock_path)" "$fleet_run_verb_nonce"
    printf 'roundhouse: the working copy carries unpublished edits (%s); run `roundhouse fleet-run` first so this commit carries only %s\n' \
      "$(printf '%s\n' "$fleet_run_verb_foreign" | head -3 | tr '\n' ' ' | sed 's/ $//')" \
      "$3" >&2
    return 65
  }
}

fleet_compact_alerts_command() (
  # `roundhouse fleet-compact-alerts` — §6.4's one-time collapse of THIS host's
  # stamped alert files (alerts/<this host>/ only) to one keyed file per
  # (kind, item), keeping the latest record each key wrote. It PUBLISHES, through
  # the same fleet_run_publish/fleet_vcs_publish path the run uses (first-push
  # gate, redaction sweep, conflict guards), because the point is to take the
  # deletions off every peer's tree, and it holds the run lock while it works.
  # Idempotent: a second invocation finds one file per key and publishes
  # nothing.
  fleet_run_env
  require_jq
  require_yq
  compact_store=$(fleet_store_path)
  compact_host=$(fleet_host_name)
  fleet_run_verb_begin "$compact_store" "$compact_host" fleet-compact-alerts ||
    exit $?
  compact_lock=$(fleet_lock_path)
  compact_tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-compact-alerts.XXXXXX")
  trap 'fleet_lock_release "$compact_lock" "$fleet_run_verb_nonce"; rm -rf "$compact_tmp"' \
    EXIT HUP INT TERM
  compact_counts=$(fleet_alerts_compact "$compact_store" "$compact_host" \
    "$compact_tmp") || {
    printf 'roundhouse: alert compaction failed; nothing published\n' >&2
    exit 65
  }
  # shellcheck disable=SC2086 # three counts, one per word
  set -- $compact_counts
  printf 'roundhouse: alerts/%s: %s keyed file(s) written, %s file(s) removed, %s left in place (unreadable or not alert-shaped)\n' \
    "$compact_host" "${1:-0}" "${2:-0}" "${3:-0}"
  if [ "$(jj -R "$compact_store" log -r @ --no-graph -T 'if(empty,"y","n")')" = y ]; then
    printf 'roundhouse: nothing to publish\n'
    exit 0
  fi
  fleet_run_publish "$compact_store" "$compact_host" interactive/human \
    "compact alerts/$compact_host to one file per alert (§6.4)" - \
    "compact alerts on $compact_host" || exit $?
  printf 'roundhouse: published the compaction\n'
)

fleet_disown_host_only() {
  # fleet_disown_host_only STORE HOST -> the items in applied/<HOST>.yaml that
  # nothing but HOST's own layer asks for: applied, and absent from the item
  # universe of the fold without the host tier (definitions items included,
  # since they come from no host layer at all). One per line, sorted.
  LC_ALL=C comm -23 \
    <(fleet_record_read "$(fleet_applied_path "$1" "$2")" '{}' |
      jq -r '(.items // {}) | keys[]' | LC_ALL=C sort -u) \
    <(fleet_run_item_digests "$(fleet_fold_shared "$1" "$2")" "$1" |
      awk '{ print $1 }' | LC_ALL=C sort -u)
}

fleet_disown_command() (
  # `roundhouse fleet-disown [--dry-run] [--host-only] [ITEM...]` — §8.2 P0's
  # one-shot release of ownership. Each item leaves applied/<this host>.yaml
  # through fleet_applied_forget and is journaled `disowned`: it is NOT
  # uninstalled, NOT counted against the removal cap (nothing is removed), and
  # NOT journaled `reverted` (nothing was withdrawn). It becomes unmanaged —
  # neither removed nor spread — which is what retiring a host-layer machine
  # snapshot needs: without this, deleting the snapshot reads as one removal
  # per item it carried, and the cap holds the lot.
  #
  # `--host-only` selects every owned item that only this host's own layer
  # asks for (fleet_disown_host_only). `--dry-run` prints the selection and
  # changes nothing. A real disown takes the run lock and publishes, like
  # fleet-compact-alerts.
  fleet_run_env
  require_jq
  require_yq
  disown_dry=false
  disown_host_only=false
  disown_named=
  while [ $# -gt 0 ]; do
    case $1 in
      --dry-run) disown_dry=true ;;
      --host-only) disown_host_only=true ;;
      -*)
        printf 'roundhouse: unknown fleet-disown option: %s\n' "$1" >&2
        exit 64
        ;;
      *)
        fleet_item_split "$1" >/dev/null || {
          printf 'roundhouse: %s is not an item id (<category>.<name>)\n' "$1" >&2
          exit 64
        }
        disown_named="$disown_named$1
"
        ;;
    esac
    shift
  done
  [ "$disown_host_only" = true ] || [ -n "$disown_named" ] || {
    printf 'roundhouse: fleet-disown needs --host-only or at least one item\n' >&2
    exit 64
  }
  disown_store=$(fleet_store_path)
  disown_host=$(fleet_host_name)
  if [ "$disown_dry" = true ]; then
    fleet_vcs_store_ready "$disown_store" || exit $?
  else
    fleet_run_verb_begin "$disown_store" "$disown_host" fleet-disown || exit $?
    disown_lock=$(fleet_lock_path)
    trap 'fleet_lock_release "$disown_lock" "$fleet_run_verb_nonce"' EXIT HUP INT TERM
  fi
  disown_selection=$(
    printf '%s' "$disown_named"
    [ "$disown_host_only" != true ] ||
      fleet_disown_host_only "$disown_store" "$disown_host"
  )
  disown_selection=$(printf '%s\n' "$disown_selection" | grep . | LC_ALL=C sort -u || true)
  # A named item this host does not own has nothing to disown, and silently
  # skipping it would let a typo read as done.
  disown_unowned=
  while IFS= read -r disown_item; do
    [ -n "$disown_item" ] || continue
    [ -n "$(fleet_applied_digest "$disown_store" "$disown_host" "$disown_item")" ] ||
      disown_unowned="$disown_unowned $disown_item"
  done <<EOF
$disown_selection
EOF
  [ -z "$disown_unowned" ] || {
    printf 'roundhouse: not in applied/%s.yaml, so not owned here:%s\n' \
      "$disown_host" "$disown_unowned" >&2
    exit 65
  }
  disown_count=$(printf '%s\n' "$disown_selection" | grep -c . || true)
  if [ "$disown_dry" = true ]; then
    printf 'roundhouse: would disown %s item(s) from applied/%s.yaml (no longer managed; left installed unless tombstoned):\n' \
      "$disown_count" "$disown_host"
  else
    printf 'roundhouse: disowning %s item(s) from applied/%s.yaml (no longer managed; left installed unless tombstoned):\n' \
      "$disown_count" "$disown_host"
  fi
  disown_fold=$(fleet_fold "$disown_store" "$disown_host")
  disown_universe=$(fleet_run_item_digests "$disown_fold" "$disown_store" |
    awk '{ print $1 }')
  # A tombstoned item is not left installed for long: disowning forgets the
  # record, and the tombstone still uninstalls what it finds.
  disown_tombstoned=$(printf '%s\n' "$disown_fold" \
    "$(fleet_fold_tombstones "$disown_store" "$disown_host" plugins)" | jq -r -s '
      [.[] | (.plugins // {}) | select(type == "object") | to_entries[] |
        select(.value == "absent" or
          ((.value | type) == "object" and .value.state == "absent")) |
        "plugins." + .key] | unique | .[]')
  while IFS= read -r disown_item; do
    [ -n "$disown_item" ] || continue
    disown_note=
    if printf '%s\n' "$disown_tombstoned" | grep -Fqx -- "$disown_item"; then
      disown_note='  (tombstoned: it will be uninstalled by its tombstone)'
    elif printf '%s\n' "$disown_universe" | grep -Fqx -- "$disown_item"; then
      disown_note='  (still in the layers: the next run adopts it again)'
    fi
    printf '  disown %s %s%s\n' "$disown_item" \
      "$(fleet_applied_digest "$disown_store" "$disown_host" "$disown_item")" "$disown_note"
  done <<EOF
$disown_selection
EOF
  [ "$disown_dry" != true ] || exit 0
  [ "$disown_count" -gt 0 ] || {
    printf 'roundhouse: nothing to disown\n'
    exit 0
  }
  disown_now=$(fleet_now)
  while IFS= read -r disown_item; do
    [ -n "$disown_item" ] || continue
    disown_digest=$(fleet_applied_digest "$disown_store" "$disown_host" "$disown_item")
    fleet_applied_forget "$disown_store" "$disown_host" "$disown_item" || {
      printf 'roundhouse: could not update applied/%s.yaml for %s; nothing published\n' \
        "$disown_host" "$disown_item" >&2
      exit 65
    }
    fleet_journal_append "$disown_store" "$disown_host" \
      "$(jq -cn --arg item "$disown_item" --arg d "$disown_digest" --arg at "$disown_now" \
        '{item:$item,digest:$d,outcome:"disowned",at:$at}')" || :
  done <<EOF
$disown_selection
EOF
  fleet_run_publish "$disown_store" "$disown_host" interactive/human \
    "disown $disown_count item(s) on $disown_host (§8.2 P0)" \
    "$(printf '%s\n' "$disown_selection" | tr '\n' ' ')" \
    "disown on $disown_host" || exit $?
  printf 'roundhouse: published the disown\n'
)
