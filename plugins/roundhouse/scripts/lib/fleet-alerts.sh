# roundhouse — the replicated ALERTS: alerts/<host>/<kind>--<key>.yaml.
#
# §5 and §6.4 of docs/specs/2026-08-06-dsc-storage-design-v2.md. An alert is
# evidence a host publishes about a condition or an event it saw; resolving
# one is `rm` on the file. Here: the one key-to-file-name mapping, the one
# lifecycle table (condition or event, item or store), the writer, the
# per-pass check ledger and its end-of-pass sweep, and the one-time
# compaction of the stamped form. The record primitives they write through
# (fleet_record_write, the redaction floor, fleet_records_read_dir) live in
# lib/fleet-records.sh.
#
# Pure yq/jq over files: no jj. Sourced by scripts/roundhouse after
# lib/fleet-records.sh; carries definitions only.
# shellcheck shell=bash

fleet_alert_name_filter='
  # The ONE file name an alert key maps to: (kind, items), or (kind, slug) for
  # an alert that names no item. The writer and the compaction share this
  # definition, so a compacted store and a freshly written one can never
  # disagree about where an alert lives. UNAMBIGUOUS: each item is `@uri`d on
  # its own and only then joined with `,` (which `@uri` always escapes), so
  # ["a,b"] and ["a","b"] are different keys, and the name is never cut here.
  # A name over 200 characters is bounded by fleet_alert_name_bound (a prefix
  # and the sha256 of the whole name), which jq cannot compute.
  def alert_name($kind; $slug; $items):
    (($items // []) | map(tostring) | unique) as $list |
    (if ($list | length) == 0 then $slug
     elif ($list | length) == 1 then $list[0] else null end) as $raw |
    (if ($list | length) == 0 then ($slug | @uri)
     else ($list | map(@uri) | join(",")) end) as $key |
    (if $raw == $kind then ($kind | @uri)
     else ($kind | @uri) + "--" + $key end) + ".yaml";
'

fleet_alert_name_bound() {
  # `fleet_alert_name_bound NAME.yaml` -> NAME.yaml, or — for a NAME over 200
  # characters, which no filesystem's NAME_MAX may take — its first 150, `~`
  # and the sha256 of the WHOLE name: bounded, and still one name per key.
  alert_bound_base=${1%.yaml}
  if [ "${#alert_bound_base}" -le 200 ]; then
    printf '%s\n' "$1"
  else
    printf '%s~%s.yaml\n' "$(printf '%s' "$alert_bound_base" | cut -c1-150)" \
      "$(printf '%s' "$alert_bound_base" | sha256_stream)"
  fi
}

# Every alert KIND: how its alert ENDS, and what it is keyed by. The ONE table
# — fleet_alert_kinds parses it, fleet_alert_lifecycle and the aging and the
# end-of-pass sweep read it through that, and fleet-agents/SKILL.md documents
# it.
#
#   lifecycle  condition  raised while a condition holds; the check clears it
#                         when the condition no longer holds, and it never ages
#                         (its `at` is first-seen, never bumped)
#              event      a notice; every raise stamps `at` = now, and it ages
#                         out by that latest occurrence after retention
#   scope      item       one alert per item: cleared by the end-of-pass sweep
#                         (fleet_alert_sweep) when the pass CHECKED the item and
#                         did not raise it
#              store      one alert for the store: the check sets or clears it
#                         itself (fleet_alert_set)
#
# A kind not listed — a legacy kind, or one a newer build raises — is an
# EVENT: aging is the safe way for a notice nobody clears to end.
#
# `stale-host` (keyed by the silent peer), `schedule-disabled` and
# `schedule-missing` (keyed by the job, `fleet-fast`/`fleet-full`) are
# store-scoped conditions their own checks set and clear every pass
# (fleet_liveness_alerts, fleet_schedule_check).
fleet_alert_lifecycle_rows='
removal-cap            condition  store
materialization        condition  store
rollback               condition  store
layer-parse            condition  store
unknown-category       condition  store
unknown-store-dir      condition  store
ssh-render             condition  store
integrity-store-wide   condition  store
integrity              condition  item
config-key-collision   condition  item
chezmoi-coownership    condition  item
package-hold           condition  item
enabled-but-untrusted  condition  item
record-write           condition  item
identity-unavailable   condition  item
uninstall-deferred     condition  item
package-deferred       condition  item
runtime-hold           condition  item
node-runtime-unverified condition item
stale-host             condition  store
schedule-disabled      condition  store
schedule-missing       condition  store
lock-takeover          event      store
canary-override        event      item
conflict               event      item
hold                   event      item
store-moved            event      store
remote-posture         event      store
bootstrap-seed         event      store
join-unverified        event      store
roster-change          event      store
'

fleet_alert_kinds() {
  # fleet_alert_kinds LIFECYCLE [SCOPE] -> the table's kinds with that
  # lifecycle (and scope), one per line. The table's only parser, and pure
  # shell: it is asked once per alert written.
  while read -r alert_kinds_kind alert_kinds_life alert_kinds_scope; do
    [ -n "$alert_kinds_kind" ] || continue
    [ "$alert_kinds_life" = "$1" ] || continue
    [ -z "${2:-}" ] || [ "$alert_kinds_scope" = "$2" ] || continue
    printf '%s\n' "$alert_kinds_kind"
  done <<EOF
$fleet_alert_lifecycle_rows
EOF
}

fleet_alert_condition_kinds() {
  # fleet_alert_condition_kinds [SCOPE] -> the CONDITION kinds (of SCOPE).
  fleet_alert_kinds condition "$@"
}

fleet_alert_lifecycle() {
  # fleet_alert_lifecycle KIND -> `condition` or `event` (the default).
  if fleet_alert_condition_kinds | grep -Fqx -- "$1"; then
    printf 'condition\n'
  else
    printf 'event\n'
  fi
}

fleet_alert_name() {
  # fleet_alert_name KIND SLUG [ITEM...] -> the keyed file name an alert lives
  # at (fleet_alert_name_filter). The common case — one item, or none, made of
  # characters `@uri` leaves alone — is answered without a jq call, because
  # fleet_alert_clear asks it for every item of every pass.
  alert_name_kind=$1
  alert_name_slug=$2
  shift 2
  alert_name_key=
  case $# in
    0) alert_name_key=$alert_name_slug ;;
    1) alert_name_key=$1 ;;
  esac
  case $alert_name_kind in '' | *[!A-Za-z0-9._~-]*) alert_name_key= ;; esac
  case $alert_name_key in *[!A-Za-z0-9._~-]*) alert_name_key= ;; esac
  if [ -n "$alert_name_key" ] && [ "${#alert_name_kind}" -lt 90 ] &&
    [ "${#alert_name_key}" -lt 90 ]; then
    if [ "$alert_name_key" = "$alert_name_kind" ]; then
      printf '%s.yaml\n' "$alert_name_kind"
    else
      printf '%s--%s.yaml\n' "$alert_name_kind" "$alert_name_key"
    fi
    return 0
  fi
  alert_name_full=$(jq -rn --arg kind "$alert_name_kind" --arg slug "$alert_name_slug" \
    --args "$fleet_alert_name_filter"' alert_name($kind; $slug; $ARGS.positional)' "$@") ||
    return 1
  fleet_alert_name_bound "$alert_name_full"
}

fleet_alert_clear() {
  # `fleet_alert_clear STORE HOST KIND SLUG [ITEM...]` — the condition behind a
  # CONDITION alert no longer holds: remove its keyed file, if there is one.
  # The same arguments the raise passed, so the same path. Costs nothing when
  # no alert of KIND exists, which is the steady state.
  alert_clear_dir="$1/alerts/$2"
  alert_clear_kind=$3
  for alert_clear_probe in "$alert_clear_dir/$alert_clear_kind".yaml \
    "$alert_clear_dir/$alert_clear_kind"--*.yaml; do
    [ -e "$alert_clear_probe" ] && break
  done
  [ -e "$alert_clear_probe" ] || return 0
  shift 2
  alert_clear_name=$(fleet_alert_name "$@") || return 0
  rm -f "$alert_clear_dir/$alert_clear_name"
}

fleet_alert_set() {
  # `fleet_alert_set STORE HOST KIND SLUG true|false DETAIL [ITEM...]` — a check
  # reports its condition: `true` raises (fleet_alert_write), `false` clears
  # (fleet_alert_clear) the same keyed alert. One call per check, so no check
  # can raise without the matching clear.
  case $5 in
    true)
      alert_set_store=$1 alert_set_host=$2 alert_set_kind=$3 alert_set_slug=$4
      alert_set_detail=$6
      shift 6
      fleet_alert_write "$alert_set_store" "$alert_set_host" "$alert_set_kind" \
        "$alert_set_slug" "$alert_set_detail" "$@"
      ;;
    false)
      alert_set_store=$1 alert_set_host=$2 alert_set_kind=$3 alert_set_slug=$4
      shift 6
      fleet_alert_clear "$alert_set_store" "$alert_set_host" "$alert_set_kind" \
        "$alert_set_slug" "$@"
      ;;
    *) return 64 ;;
  esac
}

fleet_alert_checked() {
  # `fleet_alert_checked LEDGER KIND ITEM` — this pass EVALUATED the condition
  # behind KIND for ITEM; ITEM `*` says one whole-fold check evaluated every
  # item. Only a checked item's alert may be swept: an item the pass skipped (a
  # hold, a canary wait, a cap) keeps whatever it had.
  printf 'checked\t%s\t%s\n' "$2" "$3" >>"$1"
}

fleet_alert_items() {
  # `fleet_alert_items LEDGER < ITEMS` — the pass's whole item set, one per
  # line. An item-scoped alert whose item is in NO pass's set any more (retired
  # from the fold) has no condition left to hold, so the sweep clears it too.
  # The `universe` marker says the set was recorded even when it is EMPTY: a
  # pass whose last item left the fold has no `item` line, and without the
  # marker that read as "no set recorded" and kept the last item's alerts.
  printf 'universe\n' >>"$1"
  awk 'length { printf "item\t%s\n", $0 }' >>"$1"
}

fleet_alert_raise() {
  # `fleet_alert_raise LEDGER STORE HOST KIND SLUG DETAIL ITEM` — an
  # item-scoped alert whose condition holds: written, and noted in the pass's
  # LEDGER as both checked and raised.
  printf 'checked\t%s\t%s\nraised\t%s\t%s\n' "$4" "$7" "$4" "$7" >>"$1"
  shift
  fleet_alert_write "$@"
}

fleet_alert_sweep() {
  # `fleet_alert_sweep STORE HOST LEDGER` — the end of a pass: clear every one
  # of this host's alerts of an item-scoped CONDITION kind whose item the pass
  # checked (or retired from its item set, fleet_alert_items) and did not
  # raise. Free when there are none: a glob, no subprocess per kind without
  # alerts.
  alert_sweep_store=$1
  alert_sweep_host=$2
  alert_sweep_ledger=$3
  [ -f "$alert_sweep_ledger" ] || return 0
  alert_sweep_has_items=false
  ! grep -qx universe "$alert_sweep_ledger" || alert_sweep_has_items=true
  for alert_sweep_kind in $(fleet_alert_condition_kinds item); do
    for alert_sweep_file in "$alert_sweep_store/alerts/$alert_sweep_host/$alert_sweep_kind"--*.yaml; do
      [ -f "$alert_sweep_file" ] || continue
      alert_sweep_item=$(yq -r '.items[0] // ""' "$alert_sweep_file" 2>/dev/null) || continue
      [ -n "$alert_sweep_item" ] || continue
      grep -Fqx -e "$(printf 'checked\t%s\t%s' "$alert_sweep_kind" "$alert_sweep_item")" \
        -e "$(printf 'checked\t%s\t*' "$alert_sweep_kind")" "$alert_sweep_ledger" || {
        [ "$alert_sweep_has_items" = true ] &&
          ! grep -Fqx -- "$(printf 'item\t%s' "$alert_sweep_item")" "$alert_sweep_ledger"
      } || continue
      ! grep -Fqx -- "$(printf 'raised\t%s\t%s' "$alert_sweep_kind" "$alert_sweep_item")" \
        "$alert_sweep_ledger" || continue
      fleet_alert_clear "$alert_sweep_store" "$alert_sweep_host" "$alert_sweep_kind" \
        "$alert_sweep_kind" "$alert_sweep_item"
    done
  done
}

fleet_alert_write() {
  # `fleet_alert_write STORE HOST KIND SLUG DETAIL [ITEM...]`. Resolution is
  # `rm` on the file. There is no state machine.
  #
  # KEYED, NOT STAMPED. An alert is a condition, and a condition that is still
  # true on the next pass is the same alert: one deterministic path per (kind,
  # item), rewritten only when what it says changes. The stamped-per-write
  # form put a new file in every published commit for every standing
  # condition — one store reached ~46k alert files, every one of them signed,
  # pushed, verified by every peer and aged by a per-file pass. For a
  # CONDITION, `at` is the FIRST time it was seen and is kept across rewrites,
  # and an unchanged raise writes nothing; nothing bumps a last-seen field,
  # because that would be the same churn under another name. An EVENT is a
  # notice that happened again: each raise writes `at` = now, so it ages from
  # its latest occurrence (fleet_alert_lifecycle_rows).
  alert_store=$1
  alert_host=$2
  alert_kind=$3
  alert_slug=$4
  alert_detail=$5
  shift 5
  alert_detail=$(fleet_prose_shorten_commit_ids "$alert_detail" "$alert_store")
  fleet_replicated_text_ok "$alert_detail" || return 1
  alert_record=$(jq -cn --arg kind "$alert_kind" --arg host "$alert_host" \
    --arg detail "$alert_detail" --arg at "$(fleet_now)" --args \
    '{kind: $kind, host: $host, items: $ARGS.positional, detail: $detail, at: $at}' \
    "$@") || return 1
  alert_name=$(fleet_alert_name "$alert_kind" "$alert_slug" "$@") || return 1
  alert_file="$alert_store/alerts/$alert_host/$alert_name"
  # An EVENT is stamped with its LATEST occurrence, so it ages from the last
  # time it happened; only a condition keeps its first-seen `at` and skips an
  # unchanged rewrite.
  if [ -f "$alert_file" ] && [ "$(fleet_alert_lifecycle "$alert_kind")" = condition ]; then
    # An unreadable prior (a conflicted or hand-mangled file) is replaced
    # whole; a readable one decides whether there is anything to write.
    alert_prior=$(fleet_record_read "$alert_file" '{}' 2>/dev/null) || alert_prior=
    if [ -n "$alert_prior" ]; then
      printf '%s\n' "$alert_record" | jq -e --argjson prior "$alert_prior" '
        def body: del(.at) | .items = ((.items // []) | sort);
        ($prior | type == "object") and ($prior | body) == body' >/dev/null 2>&1 &&
        return 0
      alert_record=$(printf '%s\n' "$alert_record" | jq -c --argjson prior "$alert_prior" '
        .at = (if ($prior | type == "object") and (($prior.at // "") | type == "string")
               and ($prior.at // "") != "" then $prior.at else .at end)') || return 1
    fi
  fi
  fleet_record_write "$alert_file" "$alert_record"
}

fleet_alerts_compact() {
  # `fleet_alerts_compact STORE HOST WORKDIR` -> `<written> <removed>
  # <unreadable>`. The one-time collapse of a host's stamped alert files to
  # the keyed form: one file per (kind, item), holding the LATEST record that
  # key ever wrote. HOST's own directory only — alerts/<h>/ is §7.3
  # single-writer, and compacting a peer's would be a forged edit.
  #
  # BUILT FOR ~46k FILES: one `find`, `yq` over xargs-sized batches, one `jq`
  # for the grouping and one `rm` batch. A per-file `yq` is how the store got
  # slow in the first place. A batch that contains an unreadable file is
  # re-read file by file so one bad file costs one batch, not the run; an
  # unreadable file is left exactly where it is — nothing deletes evidence it
  # could not read.
  compact_dir=$1/alerts/$2
  compact_work=$3
  [ -d "$compact_dir" ] || {
    printf '0 0 0\n'
    return 0
  }
  find "$compact_dir" -mindepth 1 -maxdepth 1 -type f -name '*.yaml' \
    >"$compact_work/alert-paths" || return 1
  [ -s "$compact_work/alert-paths" ] || {
    printf '0 0 0\n'
    return 0
  }
  fleet_records_read_dir "$compact_dir" "$compact_work/alert-records" || return 1
  # One pass over every record: key each file the way the writer would, keep
  # the newest record per key, and emit `W<TAB>target<TAB>record` for a keeper
  # that is not already at its keyed path, `D<TAB>file` for every other member
  # of the group, and one `U<TAB>count` for the files that could not be keyed.
  compact_names="$fleet_alert_name_filter"'
    def good_records: map(select(.bad != true and (.rec | type == "object") and
        ((.rec.kind // "") | type == "string") and (.rec.kind // "") != "" and
        (.file | test("\n") | not))) | unique_by(.file);
    def record_name: (.file | split("/") | last) as $base |
      (($base | capture($stamped + "(?<slug>.+)[.]yaml$") | .slug) // null) as $slug |
      ((.rec.items // []) | if type == "array" then . else [] end) as $items |
      if $slug != null then alert_name(.rec.kind; $slug; $items)
      elif ($items | length) > 0 then alert_name(.rec.kind; ""; $items)
      else $base end;
  '
  # The few names too long to use as they are are bounded in the shell (the
  # digest is sha256, which jq has no way to compute), once per name.
  compact_long_names=$(jq -s -r --arg stamped "$fleet_record_stamped_regex" "$compact_names"'
    [good_records[] | record_name | select(length > 205)] | unique | .[]' \
    "$compact_work/alert-records") || return 1
  compact_long='{}'
  while IFS= read -r compact_long_name; do
    [ -n "$compact_long_name" ] || continue
    compact_long=$(printf '%s\n' "$compact_long" | jq -c --arg k "$compact_long_name" \
      --arg v "$(fleet_alert_name_bound "$compact_long_name")" '. + {($k): $v}') || return 1
  done <<EOF
$compact_long_names
EOF
  jq -s -r --arg dir "$compact_dir" --rawfile paths "$compact_work/alert-paths" \
    --arg stamped "$fleet_record_stamped_regex" --argjson long "$compact_long" \
    "$compact_names"'
    ($paths | split("\n") | map(select(. != ""))) as $all |
    good_records as $good |
    [ $good[] |
      (.file | split("/") | last) as $base |
      (record_name | $long[.] // .) as $name |
      {file, rec, base: $base, target: ($dir + "/" + $name)} ] |
    # A keyed destination that EXISTS but is unreadable or not alert-shaped is
    # never overwritten: its whole group, destination and stamped records
    # alike, is left exactly where it is.
    ($all - ($good | map(.file))) as $unusable |
    group_by(.target) |
    map(select(.[0].target as $t | any($unusable[]; . == $t) | not)) |
    (.[] | max_by([((.rec.at // "") | tostring), .base]) as $keep |
      (if $keep.file != $keep.target
       then "W\t\($keep.target)\t\($keep.rec | tojson)" else empty end),
      (.[] | select(.file != .target) | "D\t\(.file)")),
    "U\t\(($all - ($good | map(.file))) | length)"
    ' "$compact_work/alert-records" >"$compact_work/alert-plan" || return 1
  compact_written=0
  while IFS='	' read -r compact_op compact_path compact_rec; do
    [ "$compact_op" = W ] || continue
    fleet_record_write "$compact_path" "$compact_rec" || return 1
    compact_written=$((compact_written + 1))
  done <"$compact_work/alert-plan"
  awk -F'\t' '$1 == "D" { print $2 }' "$compact_work/alert-plan" |
    tr '\n' '\0' | xargs -0 rm -f || return 1
  printf '%s %s %s\n' "$compact_written" \
    "$(awk -F'\t' '$1 == "D"' "$compact_work/alert-plan" | grep -c . || true)" \
    "$(awk -F'\t' '$1 == "U" { print $2 }' "$compact_work/alert-plan")"
}
