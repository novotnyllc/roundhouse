# roundhouse self-check — §5 and §6.4 alerts: the keyed file name, the
# lifecycle table, the per-pass check ledger and its sweep, and the one-time
# compaction of the stamped form (lib/fleet-alerts.sh).
#
# Pure file state, like section 72; evidence aging of alerts is tested there,
# with the rest of aging.
#
# Sourced by scripts/test-roundhouse in a fixed order; not a
# standalone test file. See that driver for why.
# shellcheck shell=bash

if [ -n "$fleet_fixture_yq" ]; then
  printf 'alerts: §6.4 keyed alerts, lifecycle, sweep, compaction\n'
  (
    set -eu
    PATH=$fleet_fixture_path
    export PATH
    # shellcheck source=/dev/null
    ROUNDHOUSE_LIB_ONLY=1 . "$cli"

    rec_store="$tmp/alerts/store"
    mkdir -p "$rec_store"

    # --- §5 alerts: keyed, one file per (kind, item) ---
    fleet_alert_write "$rec_store" vireo integrity unsigned-hand-edit \
      'Commit 6705e1a3 carries no SSH signature.' plugins.impeccable ||
      fail "a clean alert was refused"
    rec_alert="$rec_store/alerts/vireo/integrity--plugins.impeccable.yaml"
    [ -f "$rec_alert" ] ||
      fail "the alert was not written under alerts/<host>/<kind>--<item>.yaml"
    [ "$(yq -r '.kind' "$rec_alert")" = integrity ] &&
      [ "$(yq -r '.items[0]' "$rec_alert")" = plugins.impeccable ] ||
      fail "the alert did not carry its kind and the items it holds"

    # §6.4: KEYED, NOT STAMPED. The same CONDITION on the next pass is the same
    # alert — one path per (kind, item), and no rewrite when only the clock
    # moved. The stamped form put a new file in every commit for every standing
    # condition, which is how one store reached ~46k alert files.
    yq -i '.at = "2026-01-01T00:00:00Z"' "$rec_alert"
    rec_alert_bytes=$(cat "$rec_alert")
    fleet_alert_write "$rec_store" vireo integrity unsigned-hand-edit \
      'Commit 6705e1a3 carries no SSH signature.' plugins.impeccable ||
      fail "re-raising an unchanged alert was refused"
    [ "$(cat "$rec_alert")" = "$rec_alert_bytes" ] ||
      fail "an unchanged alert was rewritten (a last-seen bump is the same churn)"
    [ "$(find "$rec_store/alerts/vireo" -name '*impeccable*' | grep -c .)" -eq 1 ] ||
      fail "re-raising an alert wrote a second file for the same key"
    # A changed DETAIL is a rewrite, and the first-seen time survives it.
    fleet_alert_write "$rec_store" vireo integrity unsigned-hand-edit \
      'Commit 6705e1a3 and one more carry no SSH signature.' plugins.impeccable
    [ "$(yq -r '.detail' "$rec_alert")" = \
      'Commit 6705e1a3 and one more carry no SSH signature.' ] ||
      fail "a changed alert was not rewritten"
    [ "$(yq -r '.at' "$rec_alert")" = 2026-01-01T00:00:00Z ] ||
      fail "rewriting a changed alert lost its first-seen time"
    # No item: the slug is the key, and kind == slug is just the kind.
    fleet_alert_write "$rec_store" vireo removal-cap removal-cap '7 removals'
    [ -f "$rec_store/alerts/vireo/removal-cap.yaml" ] ||
      fail "an item-less alert whose slug is its kind was not keyed by the kind"
    fleet_alert_write "$rec_store" vireo materialization materialization-refused 'refused'
    [ -f "$rec_store/alerts/vireo/materialization--materialization-refused.yaml" ] ||
      fail "two item-less alerts of one kind collapsed into one file"
    # An item that carries `/` and `@` is encoded into ONE path component.
    fleet_alert_write "$rec_store" vireo config-key-collision config-key-collision \
      'collides' 'config_files.~/.claude/settings.json'
    [ -f "$rec_store/alerts/vireo/config-key-collision--config_files.~%2F.claude%2Fsettings.json.yaml" ] ||
      fail "an item with a path separator did not land in one encoded file name"
    [ "$(find "$rec_store/alerts/vireo" -mindepth 1 -type d | grep -c . || true)" -eq 0 ] ||
      fail "an alert key escaped into a subdirectory"

    # --- every alert kind has a lifecycle, from one table ---
    for rec_kind in removal-cap integrity identity-unavailable uninstall-deferred \
      stale-host schedule-disabled schedule-missing schedule-drift; do
      [ "$(fleet_alert_lifecycle "$rec_kind")" = condition ] ||
        fail "$rec_kind is not a condition alert"
    done
    for rec_kind in lock-takeover canary-override hold never-heard-of-it; do
      [ "$(fleet_alert_lifecycle "$rec_kind")" = event ] ||
        fail "$rec_kind is not an event alert"
    done
    # The sweep's kinds come from the table's scope column.
    rec_item_kinds=$(fleet_alert_condition_kinds item | tr '\n' ' ')
    case " $rec_item_kinds" in
      *' integrity '*' package-hold '*) ;;
      *) fail "the item-scoped condition kinds are wrong: $rec_item_kinds" ;;
    esac
    case " $(fleet_alert_condition_kinds store | tr '\n' ' ')" in
      *' integrity-store-wide '*) ;;
      *) fail "the store-wide integrity hold is not a store-scoped condition" ;;
    esac
    case " $rec_item_kinds" in
      *' removal-cap '* | *' canary-override '* | *' stale-host '* | *' schedule-disabled '*)
        fail "a store-scoped or event kind is swept per item: $rec_item_kinds" ;;
    esac
    # The fast name path and the jq filter agree, and an unsafe key takes jq.
    for rec_args in 'removal-cap removal-cap' 'integrity integrity-plugins-x plugins.x' \
      'config-key-collision c config_files.~/.a/b' 'k s plugins.x@m' 'k s a b'; do
      # shellcheck disable=SC2086 # the argument vector under test
      set -- $rec_args
      rec_fast=$(fleet_alert_name "$@")
      rec_kind=$1 rec_slug=$2
      shift 2
      rec_slow=$(jq -rn --arg kind "$rec_kind" --arg slug "$rec_slug" --args \
        "$fleet_alert_name_filter"' alert_name($kind; $slug; $ARGS.positional)' "$@")
      [ "$rec_fast" = "$rec_slow" ] ||
        fail "fleet_alert_name and the shared filter disagree: $rec_fast vs $rec_slow"
    done
    # The key is UNAMBIGUOUS: an item holding a comma is not two items, and two
    # long keys that share their first 200 characters are two names, each
    # bounded under NAME_MAX.
    [ "$(fleet_alert_name hold s 'a,b')" != "$(fleet_alert_name hold s a b)" ] ||
      fail "the items [a,b] and [a, b] share one alert file"
    rec_long_a="plugins.$(printf 'x%.0s' $(seq 1 220))a"
    rec_long_b="plugins.$(printf 'x%.0s' $(seq 1 220))b"
    rec_name_a=$(fleet_alert_name integrity s "$rec_long_a")
    rec_name_b=$(fleet_alert_name integrity s "$rec_long_b")
    [ "$rec_name_a" != "$rec_name_b" ] ||
      fail "two long keys with one 200-character prefix share one alert file"
    [ "${#rec_name_a}" -le 255 ] && [ "${#rec_name_b}" -le 255 ] ||
      fail "a long alert key was not bounded under NAME_MAX"
    rec_names="$tmp/records/names"
    rm -rf "$rec_names"
    mkdir -p "$rec_names"
    fleet_alert_write "$rec_names" vireo integrity s 'long a' "$rec_long_a"
    fleet_alert_write "$rec_names" vireo integrity s 'long b' "$rec_long_b"
    [ -f "$rec_names/alerts/vireo/$rec_name_a" ] && [ -f "$rec_names/alerts/vireo/$rec_name_b" ] ||
      fail "the writer did not land two long keys at their two names"
    fleet_alert_clear "$rec_names" vireo integrity s "$rec_long_a"
    [ ! -e "$rec_names/alerts/vireo/$rec_name_a" ] && [ -f "$rec_names/alerts/vireo/$rec_name_b" ] ||
      fail "clearing one long key did not clear exactly its own file"
    # The compaction lands a stamped long-key record where the writer would.
    rm -rf "$rec_names" && mkdir -p "$rec_names/alerts/vireo" "$rec_names/work"
    printf 'kind: integrity\nhost: vireo\nitems: [%s]\ndetail: stamped\nat: "2026-08-01T00:00:00Z"\n' \
      "$rec_long_a" >"$rec_names/alerts/vireo/20260801T0000-integrity-long.yaml"
    fleet_alerts_compact "$rec_names" vireo "$rec_names/work" >/dev/null ||
      fail "the compaction failed on a long key"
    [ -f "$rec_names/alerts/vireo/$rec_name_a" ] ||
      fail "the compaction and the writer disagree about a long key's file"
    # A condition alert is CLEARED when its condition ends, and raised again
    # only if it returns.
    rec_life="$tmp/records/lifecycle"
    rm -rf "$rec_life"
    mkdir -p "$rec_life"
    fleet_alert_write "$rec_life" vireo package-hold package-hold-packages-jq \
      'no package manager on this host can provide packages.jq' packages.jq
    [ -f "$rec_life/alerts/vireo/package-hold--packages.jq.yaml" ] ||
      fail "the condition alert was not raised"
    fleet_alert_clear "$rec_life" vireo package-hold package-hold-packages-jq packages.jq
    [ ! -e "$rec_life/alerts/vireo/package-hold--packages.jq.yaml" ] ||
      fail "fleet_alert_clear left the alert behind"
    fleet_alert_clear "$rec_life" vireo package-hold package-hold-packages-jq packages.jq ||
      fail "clearing an alert that is not there failed"
    fleet_alert_write "$rec_life" vireo package-hold package-hold-packages-jq \
      'no package manager on this host can provide packages.jq' packages.jq
    [ -f "$rec_life/alerts/vireo/package-hold--packages.jq.yaml" ] ||
      fail "a returning condition was not raised again"
    fleet_alert_write "$rec_life" vireo config-key-collision config-key-collision \
      'collides' 'config_files.~/.claude/settings.json'
    fleet_alert_clear "$rec_life" vireo config-key-collision config-key-collision \
      'config_files.~/.claude/settings.json'
    [ -z "$(find "$rec_life/alerts/vireo" -name 'config-key-collision*')" ] ||
      fail "fleet_alert_clear did not find an encoded key"
    # One call per store-wide check: true raises, false clears.
    fleet_alert_set "$rec_life" vireo removal-cap removal-cap true 'over the cap' ||
      fail "fleet_alert_set true failed"
    [ -f "$rec_life/alerts/vireo/removal-cap.yaml" ] ||
      fail "fleet_alert_set true did not raise"
    fleet_alert_set "$rec_life" vireo removal-cap removal-cap false '' ||
      fail "fleet_alert_set false failed"
    [ ! -e "$rec_life/alerts/vireo/removal-cap.yaml" ] ||
      fail "fleet_alert_set false did not clear"
    # The end-of-pass sweep clears ONLY what the pass evaluated and did not
    # raise: jq raised again (kept), rg checked clean (cleared), fd skipped by
    # the pass (kept, though not raised), and an item gone from the pass's
    # item set entirely (cleared: no condition left to hold).
    rec_ledger="$rec_life/ledger"
    : >"$rec_ledger"
    for rec_item in rg fd gone; do
      fleet_alert_write "$rec_life" vireo package-hold "package-hold-packages-$rec_item" \
        "no package manager on this host can provide packages.$rec_item" \
        "packages.$rec_item"
    done
    printf '%s\n' packages.jq packages.rg packages.fd | fleet_alert_items "$rec_ledger"
    fleet_alert_raise "$rec_ledger" "$rec_life" vireo package-hold package-hold-packages-jq \
      'no package manager on this host can provide packages.jq' packages.jq
    fleet_alert_checked "$rec_ledger" package-hold packages.rg
    fleet_alert_sweep "$rec_life" vireo "$rec_ledger"
    [ -f "$rec_life/alerts/vireo/package-hold--packages.jq.yaml" ] ||
      fail "the sweep cleared an alert the pass raised"
    [ ! -e "$rec_life/alerts/vireo/package-hold--packages.rg.yaml" ] ||
      fail "the sweep kept an alert whose condition the pass checked clean"
    [ -f "$rec_life/alerts/vireo/package-hold--packages.fd.yaml" ] ||
      fail "the sweep cleared an alert for an item the pass skipped"
    [ ! -e "$rec_life/alerts/vireo/package-hold--packages.gone.yaml" ] ||
      fail "the sweep kept an alert for an item retired from the fold"
    # An EMPTY item set is still a recorded set: the pass whose last item left
    # the fold sweeps that item's alerts.
    rec_empty_ledger="$rec_life/ledger-empty"
    : >"$rec_empty_ledger"
    fleet_alert_write "$rec_life" vireo package-hold package-hold-packages-last \
      'held' packages.last
    fleet_alert_items "$rec_empty_ledger" </dev/null
    fleet_alert_sweep "$rec_life" vireo "$rec_empty_ledger"
    [ ! -e "$rec_life/alerts/vireo/package-hold--packages.last.yaml" ] ||
      fail "the last item to leave the fold kept its alert"
    # No set recorded at all (a ledger nothing wrote an item set to) clears
    # nothing that was not checked.
    fleet_alert_write "$rec_life" vireo package-hold package-hold-packages-kept \
      'held' packages.kept
    : >"$rec_empty_ledger"
    fleet_alert_sweep "$rec_life" vireo "$rec_empty_ledger"
    [ -f "$rec_life/alerts/vireo/package-hold--packages.kept.yaml" ] ||
      fail "a sweep with no recorded item set cleared an unchecked alert"
    rm -f "$rec_life/alerts/vireo/package-hold--packages.kept.yaml"
    # A whole-fold check marks every item of its kind checked.
    fleet_alert_write "$rec_life" vireo chezmoi-coownership chezmoi-coownership \
      'co-owned' 'config_files.~/.a'
    fleet_alert_checked "$rec_ledger" chezmoi-coownership '*'
    fleet_alert_sweep "$rec_life" vireo "$rec_ledger"
    [ -z "$(find "$rec_life/alerts/vireo" -name 'chezmoi-coownership*')" ] ||
      fail "a whole-fold check did not sweep its ended alert"
    # A condition keeps its first-seen `at`; an event takes its latest.
    (
      fleet_now() { printf '2026-09-01T00:00:00Z\n'; }
      fleet_alert_write "$rec_life" vireo package-hold package-hold-packages-at \
        'held' packages.at
      fleet_alert_write "$rec_life" vireo canary-override canary-override \
        'bypassed' plugins.x
    )
    (
      fleet_now() { printf '2026-09-20T00:00:00Z\n'; }
      fleet_alert_write "$rec_life" vireo package-hold package-hold-packages-at \
        'held' packages.at
      fleet_alert_write "$rec_life" vireo canary-override canary-override \
        'bypassed' plugins.x
    )
    [ "$(yq -r '.at' "$rec_life/alerts/vireo/package-hold--packages.at.yaml")" = \
      2026-09-01T00:00:00Z ] || fail "a re-raised condition lost its first-seen at"
    [ "$(yq -r '.at' "$rec_life/alerts/vireo/canary-override--plugins.x.yaml")" = \
      2026-09-20T00:00:00Z ] || fail "a re-raised event did not take its latest at"

    # --- §6.4 the one-time compaction of the stamped form ---
    rec_compact="$tmp/records/compact"
    rm -rf "$rec_compact"
    mkdir -p "$rec_compact/store/alerts/vireo" "$rec_compact/store/alerts/wren" \
      "$rec_compact/work"
    rec_compact_dir="$rec_compact/store/alerts/vireo"
    for rec_n in 1 2 3; do
      printf 'kind: integrity\nhost: vireo\nitems: [plugins.ponytail]\ndetail: held %s\nat: "2026-08-0%sT00:00:00Z"\n' \
        "$rec_n" "$rec_n" >"$rec_compact_dir/2026080${rec_n}T0000-integrity-plugins-ponytail.yaml"
      printf 'kind: removal-cap\nhost: vireo\nitems: []\ndetail: %s removals\nat: "2026-08-0%sT00:00:00Z"\n' \
        "$rec_n" "$rec_n" >"$rec_compact_dir/2026080${rec_n}T0000-removal-cap.yaml"
    done
    # A keyed file already written by the new writer joins its group.
    printf 'kind: removal-cap\nhost: vireo\nitems: []\ndetail: 9 removals\nat: "2026-08-09T00:00:00Z"\n' \
      >"$rec_compact_dir/removal-cap.yaml"
    printf '<<<<<<< Conflict 1 of 1\n: : not yaml\n' \
      >"$rec_compact_dir/20260801T0000-broken.yaml"
    printf 'kind: integrity\nhost: wren\nitems: []\ndetail: a peer\nat: "2026-08-01T00:00:00Z"\n' \
      >"$rec_compact/store/alerts/wren/20260801T0000-integrity.yaml"
    rec_counts=$(fleet_alerts_compact "$rec_compact/store" vireo "$rec_compact/work") ||
      fail "the alert compaction failed"
    [ "$rec_counts" = '1 6 1' ] ||
      fail "the compaction did not write one keyed file, remove six and leave one: $rec_counts"
    [ "$(yq -r '.detail' "$rec_compact_dir/integrity--plugins.ponytail.yaml")" = 'held 3' ] ||
      fail "the compaction did not keep the latest record for the key"
    [ "$(yq -r '.detail' "$rec_compact_dir/removal-cap.yaml")" = '9 removals' ] ||
      fail "the compaction displaced a newer keyed record with an older stamped one"
    [ -z "$(find "$rec_compact_dir" -name '2026080?T0000-*' ! -name '*-broken.yaml')" ] ||
      fail "stamped alert files survived the compaction"
    [ -f "$rec_compact_dir/20260801T0000-broken.yaml" ] ||
      fail "the compaction deleted a file it could not read"
    [ -f "$rec_compact/store/alerts/wren/20260801T0000-integrity.yaml" ] ||
      fail "the compaction touched another host's alerts"
    [ "$(fleet_alerts_compact "$rec_compact/store" vireo "$rec_compact/work")" = '0 0 1' ] ||
      fail "a second compaction was not a no-op"
    # A keyed DESTINATION that exists but cannot be read (a jj conflict) or is
    # not alert-shaped is never overwritten, and its stamped group stays too.
    rec_cdest="$tmp/records/compact-dest"
    rm -rf "$rec_cdest"
    mkdir -p "$rec_cdest/store/alerts/vireo" "$rec_cdest/work"
    rec_cdest_dir="$rec_cdest/store/alerts/vireo"
    printf '<<<<<<< Conflict 1 of 1\n: : not yaml\n' >"$rec_cdest_dir/rollback.yaml"
    printf -- '- not\n- an alert\n' >"$rec_cdest_dir/layer-parse.yaml"
    for rec_n in 1 2; do
      for rec_kind in rollback layer-parse; do
        printf 'kind: %s\nhost: vireo\nitems: []\ndetail: d%s\nat: "2026-08-0%sT00:00:00Z"\n' \
          "$rec_kind" "$rec_n" "$rec_n" >"$rec_cdest_dir/2026080${rec_n}T0000-$rec_kind.yaml"
      done
    done
    rec_cdest_before=$(cat "$rec_cdest_dir/rollback.yaml" "$rec_cdest_dir/layer-parse.yaml")
    fleet_alerts_compact "$rec_cdest/store" vireo "$rec_cdest/work" >/dev/null ||
      fail "the compaction failed over an unusable destination"
    [ "$(cat "$rec_cdest_dir/rollback.yaml" "$rec_cdest_dir/layer-parse.yaml")" = "$rec_cdest_before" ] ||
      fail "the compaction overwrote an unreadable or non-alert keyed destination"
    [ "$(find "$rec_cdest_dir" -name '2026080?T0000-*' | grep -c .)" -eq 4 ] ||
      fail "the compaction removed the stamped records of a group it could not land"
    # Compaction and the writer agree on the key, so the next raise of a
    # compacted condition finds its file and writes nothing.
    rec_alert_bytes=$(cat "$rec_compact_dir/integrity--plugins.ponytail.yaml")
    ROUNDHOUSE_FLEET_STORE="$rec_compact/store" \
      fleet_alert_write "$rec_compact/store" vireo integrity \
      integrity-plugins-ponytail 'held 3' plugins.ponytail
    [ "$(cat "$rec_compact_dir/integrity--plugins.ponytail.yaml")" = "$rec_alert_bytes" ] ||
      fail "the writer and the compaction disagree about an alert's key"
    # Efficiency is structural: batched yq, no per-file subprocess.
    cli_function_body fleet_alerts_compact | grep -q 'fleet_records_read_dir' &&
      cli_function_body fleet_records_read_dir | grep -q 'xargs -0 -n 256 bash -c' ||
      fail "the compaction no longer batches its reads"
  )
fi
