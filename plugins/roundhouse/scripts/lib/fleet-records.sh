# roundhouse — the replicated records: what a host publishes about itself.
#
# §5 and §10 of docs/specs/2026-08-06-dsc-storage-design-v2.md. Every shape
# here is EVIDENCE, never authorization: the verdict that permitted an apply,
# and its reason, live host-local in store.run/ and are never replicated. The
# one exception is `outcome: resolved`, which carries a rationale because a
# conflict resolution is a fleet-affecting decision no other artifact records
# and peers must be able to see why.
#
# No `schema:` and no `schema_version:` anywhere. A DSC record is a human-first
# document; a version key on it is ceremony that invites a validator, and §14
# deletes both.
#
# Pure yq/jq over files: no jj. A record's CONTENT is decided here, and the
# commit that publishes it is the run driver's business.
#
# Sourced by scripts/roundhouse; carries definitions only.
# shellcheck shell=bash

fleet_upstream_id_valid() {
  # Upstream IDs become one path component under upstreams/. Marketplace names
  # use the same portable character set as the sealed executor manifest, but
  # `.` and `..` remain traversal components even though dots are otherwise
  # valid. Validate both before invoking a manager and at the record sink.
  case ${1:-} in
    ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

fleet_record_write() {
  # Every record in this unit lands through here: JSON in, YAML on disk,
  # atomically, owner-only, never following a symlink. One writer, so no
  # record kind can drift into its own file semantics.
  # REFUSE TO WRITE NOTHING, and this guard is load-bearing rather than
  # defensive. Every caller composes its argument as `fleet_record_read … | jq
  # …` inside a command substitution, and there is no `pipefail` in this
  # program: when `yq` fails on an unparsable or conflict-markered file, `jq`
  # reads empty stdin, emits nothing and exits 0. `printf '' | yq -P -p=json`
  # then SUCCEEDS too, so the `|| return 1` below never fires and safe_output
  # atomically installs a one-byte file over a signed, replicated record —
  # applied/<h>.yaml (the only thing that makes a removal legal, §5) or
  # journal/<h>/<d>.yaml (what §10.8 needs to stop a revert auto-applying).
  # The truncation is then signed and pushed to every peer.
  [ -n "$2" ] || {
    printf 'roundhouse: refusing to write an empty record to %s\n' "$1" >&2
    return 1
  }
  record_dir=$(dirname "$1")
  mkdir -p "$record_dir"
  record_tmp=$(mktemp "${TMPDIR:-/tmp}/roundhouse-record.XXXXXX") || return 1
  printf '%s\n' "$2" | yq -P -p=json -o=yaml >"$record_tmp" || {
    rm -f "$record_tmp"
    return 1
  }
  [ -s "$record_tmp" ] || {
    rm -f "$record_tmp"
    return 1
  }
  # safe_output's status is the answer, so it is captured rather than left to
  # be overwritten by the `rm` that used to be the last command in this
  # function — which made a failed write return 0.
  record_status=0
  safe_output "$record_tmp" "$1" || record_status=$?
  rm -f "$record_tmp"
  return "$record_status"
}

fleet_record_read() {
  # A record file as compact JSON, or the caller's default when it is absent.
  # An absent record and an empty one are the same answer everywhere in this
  # unit: a host that has never journaled has journaled nothing.
  # An UNREADABLE record is not an empty one. yq's failure is captured rather
  # than allowed to become empty stdout, because every caller pipes this into
  # `jq` and jq exits 0 on empty stdin — so a parse failure would read as clean
  # data all the way to the writer.
  [ -f "$1" ] || {
    printf '%s\n' "${2:-null}"
    return
  }
  record_read_out=$(yq -o=json -I=0 ". // ${2:-null}" "$1") || return 1
  [ -n "$record_read_out" ] || return 1
  printf '%s\n' "$record_read_out"
}

fleet_record_stamp() {
  # The `20260807T0914` prefix alerts and findings are named by.
  date -u +%Y%m%dT%H%M
}

# The STAMPED file name (`<YYYYMMDDTHHMM>-<slug>.yaml`) — every finding, and
# every alert an older build wrote — defined once for compaction and aging.
fleet_record_stamped_regex='^[0-9]{8}T[0-9]{4}-'

# --- §10.4 the redaction floor ------------------------------------------------

fleet_replicated_cap=400

fleet_replicated_text_ok() {
  # Every field a record replicates passes through here. Two independent
  # rules, and a trip REFUSES rather than silently redacting — §10.4's own
  # remedy cannot un-publish, so the only workable moment is before the write.
  #
  #   fleet_quote_is_secret   the named secret classes plus one bounded
  #                           32-char entropy check, carried verbatim from the
  #                           shipped code
  #   the 400-byte cap        on every replicated free-text field, including
  #                           the commit trailers phase 10 sweeps: a rationale
  #                           that does not fit belongs in store.run/, not on
  #                           the wire
  ! fleet_quote_is_secret "$1" || {
    printf 'roundhouse: refusing to replicate text matching a secret class\n' >&2
    return 1
  }
  [ "$(printf '%s' "$1" | wc -c | tr -d ' ')" -le "$fleet_replicated_cap" ] || {
    printf 'roundhouse: refusing to replicate free text over %s bytes\n' \
      "$fleet_replicated_cap" >&2
    return 1
  }
}

# --- §5 journal/<host>/<date>.yaml -------------------------------------------

fleet_journal_path() {
  # Appended by one host only, so it cannot conflict. The date comes from the
  # record's own `at`, never from the clock at write time, so a record and the
  # file holding it can never disagree about which day it belongs to.
  printf '%s/journal/%s/%s.yaml\n' "$1" "$2" "${3%%T*}"
}

fleet_journal_entry_ok() {
  # Evidence only: item, digest, outcome, host, time. Not authorization, and
  # not prose.
  #
  # `signer:` is refused because it restates in self-asserted, unverifiable
  # form what §7.3 verifies cryptographically — a field that invites someone
  # to trust it. `held_reason:` is the reason the judges scoped OUT of the
  # replicated record, and `layers:` is recomputed by fleet-explain. All three
  # live in store.run/ instead, and a writer that tries to put them back gets
  # a refusal rather than a review round.
  printf '%s\n' "$1" | jq -e '
    (has("signer") or has("layers") or has("held_reason") or
     has("schema") or has("schema_version") | not) and
    (.at | type == "string") and
    (.outcome as $o |
      if $o == "alive" then
        # A run-level heartbeat: no item, written once per completed run.
        (has("item") | not)
      elif $o == "unreachable" then
        # §6/convergence.md: the remote was unreachable this run, so the host
        # converged from last known and fetched nothing — `source: none`, no
        # item, a run-level fact like the heartbeat.
        (has("item") | not) and (.source == "none")
      elif $o == "resolved" then
        # The one replicated record that carries a rationale, and it names
        # BOTH parents by change id so a peer can audit the decision.
        (.item | type == "string") and (.digest | type == "string") and
        ((.sides // []) | length) == 2 and
        all(.sides[]; (.change | type == "string") and (.host | type == "string")) and
        (.resolution | type == "string")
      elif ($o == "applied" or $o == "satisfied" or $o == "held" or
            $o == "reverted" or $o == "disowned") then
        # `disowned` is an OWNERSHIP record, not a value one: this host
        # stopped managing the item (fleet-disown) and left it installed. It
        # is not `reverted` — nothing was withdrawn, so it neither withdraws
        # canary evidence nor reads as half of a revert signature.
        # `applied` claims only "the run refused nothing" — a weaker claim
        # than a health probe, and the design does not pretend otherwise.
        # `satisfied` is the no-op-BECAUSE-CORRECT record: the item resolved,
        # was reviewed, and this design has no state-alignment verb to run for
        # it (declared boundary B-3), so there was nothing to do. It is a
        # DISTINCT outcome from `held` on purpose — an audit that cannot tell
        # "no-op because correct" from "no-op because blocked" cannot answer
        # the only question anyone asks of the journal.
        (.item | type == "string") and (.digest | type == "string")
      else false end)' >/dev/null 2>&1
}

fleet_journal_append() {
  # `fleet_journal_append STORE HOST ENTRY_JSON`.
  journal_at=$(printf '%s\n' "$3" | jq -r '.at // empty')
  [ -n "$journal_at" ] || return 1
  fleet_journal_entry_ok "$3" || {
    printf 'roundhouse: refusing a journal entry that is not evidence-shaped\n' >&2
    return 1
  }
  journal_file=$(fleet_journal_path "$1" "$2" "$journal_at")
  fleet_record_write "$journal_file" \
    "$(fleet_record_read "$journal_file" '[]' | jq -c --argjson e "$3" '. + [$e]')"
}

fleet_journal_entries() {
  # Every entry a host has published, oldest file first, as JSON lines. The
  # canary gate and doctor both read the directory this way; nothing reads a
  # single date.
  #
  # A DAY-FILE THAT DOES NOT PARSE MAKES THE READ INCOMPLETE, AND THAT IS
  # SIGNALLED, NOT SWALLOWED. A jj-conflicted `journal/<h>/*.yaml` — exactly
  # where a `held`/`reverted` record lands mid-divergence — used to be skipped
  # silently, so §10.1's canary condition 2 ("nothing later withdrew it") read
  # clean off the surviving files while the withdrawal sat unreadable. The
  # entries that DO parse are still emitted (a caller that only reports wants
  # them), but a non-zero return tells the gate its evidence is partial.
  journal_dir="$1/journal/$2"
  [ -d "$journal_dir" ] || return 0
  journal_rc=0
  for journal_file in "$journal_dir"/*.yaml; do
    [ -f "$journal_file" ] || continue
    yq -o=json -I=0 '(. // []) | .[]' "$journal_file" 2>/dev/null || journal_rc=1
  done
  return "$journal_rc"
}

# How far back fleet-doctor counts `--now` canary bypasses, in days; aging
# keeps every `override` record inside it. One value for both, so the reader's
# window and the records it needs cannot drift apart.
fleet_journal_override_window_days=30

fleet_journal_load_bearing_filter='
  # The journal records something still READS, as `"<file>\t<index>"` keys:
  # aging may delete any other record past retention, and these never. One
  # definition, so a new reader of the journal adds its rows HERE. Input: an
  # array of {file, i, r}, every record of ONE host; $recent: the cut for
  # readers with a window of their own.
  #
  #   evidence      the OLDEST and the NEWEST `applied` and `satisfied` per
  #                 (item, digest): the canary gate takes its wait from the
  #                 oldest and §8.2b rule 5 its time from the newest, and the
  #                 revert signature (§10.8) needs "this digest was applied"
  #   withdrawals   every `held` or `reverted` NEWER than its item'"'"'s oldest
  #                 evidence: canary condition 2 ("nothing later withdrew it")
  #                 and the revert signature'"'"'s "current" value read them
  #   liveness      the newest `alive`, and the newest record of any kind:
  #                 canary condition 3 asks for SOME record after the wait
  #   overrides     `override` records newer than $recent: fleet-doctor counts
  #                 the `--now` canary bypasses of the last
  #                 fleet_journal_override_window_days
  def journal_load_bearing($recent):
    map(select(.r | type == "object")) as $recs |
    def at: (.r.at // "") | tostring;
    ([$recs[] | select((.r.outcome == "applied" or .r.outcome == "satisfied") and
        (.r.item | type) == "string")] |
      group_by([.r.item, ((.r.digest // "") | tostring), .r.outcome]) |
      map((min_by(at)), (max_by(at)))) as $evidence |
    ($evidence | group_by(.r.item) |
      map({key: .[0].r.item, value: (map(at) | min)}) | from_entries) as $since |
    [$recs[] | select((.r.outcome == "held" or .r.outcome == "reverted") and
      (.r.item | type) == "string" and $since[.r.item] != null and
      at > $since[.r.item])] as $withdrawals |
    ([$recs[] | select(.r.outcome == "alive")] |
      if length == 0 then [] else [max_by(at)] end) as $alive |
    (if ($recs | length) == 0 then [] else [$recs | max_by(at)] end) as $newest |
    [$recs[] | select(.r.override != null and at >= $recent)] as $overrides |
    [($evidence + $withdrawals + $alive + $newest + $overrides)[] |
      "\(.file)\t\(.i)"] | unique;
'

fleet_records_read_dir() {
  # `fleet_records_read_dir DIR OUT` — every `*.yaml` directly in DIR as JSON
  # lines `{"file": PATH, "rec": DOCUMENT}` in OUT, and `{"file", "bad": true}`
  # for a file that does not parse. Built for tens of thousands of files: one
  # `find`, `yq` over xargs-sized batches, and a batch holding an unreadable
  # file re-read file by file, so one bad file costs one batch. Exit 0 with an
  # empty OUT when there is nothing to read.
  : >"$2" || return 1
  [ -d "$1" ] || return 0
  records_read_list=$(mktemp "${TMPDIR:-/tmp}/roundhouse-records.XXXXXX") || return 1
  find "$1" -mindepth 1 -maxdepth 1 -type f -name '*.yaml' -print0 \
    >"$records_read_list" || { rm -f "$records_read_list"; return 1; }
  # An empty list must not reach xargs: with no arguments it still runs the
  # command once, and a `yq` with no file reads stdin.
  if [ -s "$records_read_list" ]; then
    # shellcheck disable=SC2016 # the inner script is bash -c's, expanded there
    # A batch's output is BUFFERED and emitted only when its yq succeeds: yq
    # prints every record before the bad one first, so streaming it and then
    # re-reading the batch file by file would emit those records twice.
    xargs -0 -n 256 bash -c '
      if records_out=$(yq -o=json -I=0 "{\"file\": filename, \"rec\": .}" "$@" 2>/dev/null); then
        [ -z "$records_out" ] || printf "%s\n" "$records_out"
        exit 0
      fi
      for records_file do
        if records_out=$(yq -o=json -I=0 "{\"file\": filename, \"rec\": .}" "$records_file" 2>/dev/null); then
          [ -z "$records_out" ] || printf "%s\n" "$records_out"
        else
          jq -cn --arg f "$records_file" "{file: \$f, bad: true}"
        fi
      done' records <"$records_read_list" >"$2" || {
      rm -f "$records_read_list"
      return 1
    }
  fi
  rm -f "$records_read_list"
}

fleet_records_retention_days() {
  # fleet_records_retention_days FOLD -> the evidence retention window in days,
  # from `policy.evidence_retention_days` (V2's policy block).
  # THE WINDOW HAS A FLOOR: it is read from store content, it is not an item
  # (no digest, no verdict, no canary gate, outside fleet_removal_cap), and
  # its consequence is deleting evidence on every host — so a value under 7
  # reads as 7 (`evidence_retention_days: 0` would otherwise wipe the fleet's
  # replicated evidence from one unreviewable scalar). A non-numeric value
  # falls back to the default rather than to the floor: a typo should keep
  # more evidence, not less.
  printf '%s\n' "$1" | jq -r '
    (.policy.evidence_retention_days // 90) as $d |
    if ($d | type) == "number" then ([$d, 7] | max | floor) else 90 end'
}

fleet_records_age() {
  # fleet_records_age STORE HOST RETENTION-DAYS [--dry-run] — §7.11.3's
  # second policy, DELIBERATELY DECOUPLED from trust checkpointing. They have
  # different natural periods (a canary window is hours, a trust checkpoint is
  # months) and coupling them would mean keeping evidence far too long or
  # re-rooting far too often. Evidence paths are never inputs to verification,
  # so aging them carries no trust reasoning — but some RECORDS are inputs to
  # other gates, and those are never aged (fleet_journal_load_bearing_filter).
  #
  # HOST's OWN evidence only (journal/<h>/, alerts/<h>/, findings/<h>/): those
  # paths are §7.3 single-writer, and a host that trimmed a peer's would author
  # a commit its peers refuse. The changes land in the working copy, so they
  # publish through the ordinary run (or `fleet-age-evidence`).
  #
  #   journal   aged per RECORD by its own `at`; a day file is rewritten with
  #             what remains, or removed when nothing does
  #   alerts    a keyed CONDITION alert never ages (fleet_alert_lifecycle);
  #             event alerts, unknown kinds and legacy stamped files age by `at`
  #   findings  each file by its `at`
  #
  # Batched throughout: one read per directory (fleet_records_read_dir), one
  # jq plan, one `rm` batch, and a `yq` only per day file that is rewritten.
  # Prints one summary line; `--dry-run` prints it and changes nothing.
  age_store=$1
  age_host=$2
  age_dry=false
  [ "${4:-}" != --dry-run ] || age_dry=true
  age_cutoff=$(fleet_doctor_days_ago "$3")
  age_recent=$(fleet_doctor_days_ago "$fleet_journal_override_window_days")
  age_work=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-age.XXXXXX") || return 1
  age_rc=0
  {
    fleet_records_read_dir "$age_store/journal/$age_host" "$age_work/journal" &&
      jq -s -r --arg cutoff "$age_cutoff" --arg recent "$age_recent" \
        "$fleet_journal_load_bearing_filter"'
        # ANY unreadable day file stops journal aging outright: what is
        # load-bearing is decided over the WHOLE history, and a withdrawal
        # in a readable file is only safe to drop when the record it
        # withdraws is visible too.
        ([ .[] | select(.bad == true or (.rec | type) != "array") ] | length) as $bad |
        if $bad > 0 then "X\tjournal\t\($bad)" else (
        [ .[] | select(.bad != true and (.rec | type) == "array") ] as $files |
        [ $files[] as $f | $f.rec | to_entries[] | {file: $f.file, i: .key, r: .value} ]
          as $all |
        ($all | journal_load_bearing($recent) |
          map({key: ., value: true}) | from_entries) as $keep |
        def aged: ((.r.at // "") | type) == "string" and (.r.at // "") != "" and
          .r.at < $cutoff and ($keep["\(.file)\t\(.i)"] | not);
        ($all | map(select(aged)) | length) as $gone |
        ($all | group_by(.file) | map(. as $mine |
          ($mine | map(select(aged | not)) | sort_by(.i) | map(.r)) as $left |
          if ($left | length) == ($mine | length) then empty
          elif ($left | length) == 0 then "D\t\($mine[0].file)"
          else "W\t\($mine[0].file)\t\($left | tojson)" end) | .[]),
        "N\tjournal\t\($gone)\t\($all | length)") end' "$age_work/journal" \
        >"$age_work/plan" &&
      fleet_records_read_dir "$age_store/alerts/$age_host" "$age_work/alerts" &&
      jq -s -r --arg cutoff "$age_cutoff" --arg stamped "$fleet_record_stamped_regex" \
        --arg conditions "$(fleet_alert_condition_kinds)" '
        ($conditions | split("\n") | map(select(. != "")) |
          map({key: ., value: true}) | from_entries) as $condition |
        [ .[] | select(.bad != true and (.rec | type) == "object") |
          ((.file | split("/") | last) | test($stamped)) as $legacy |
          select($legacy or ($condition[(.rec.kind // "") | tostring] | not)) |
          select(((.rec.at // "") | type) == "string" and (.rec.at // "") != "" and
            .rec.at < $cutoff) | "D\t\(.file)" ] as $d |
        ($d[]), "N\talerts\t\($d | length)\t\(length)"' "$age_work/alerts" \
        >>"$age_work/plan" &&
      fleet_records_read_dir "$age_store/findings/$age_host" "$age_work/findings" &&
      jq -s -r --arg cutoff "$age_cutoff" '
        [ .[] | select(.bad != true and (.rec | type) == "object") |
          select(((.rec.at // "") | type) == "string" and (.rec.at // "") != "" and
            .rec.at < $cutoff) | "D\t\(.file)" ] as $d |
        ($d[]), "N\tfindings\t\($d | length)\t\(length)"' "$age_work/findings" \
        >>"$age_work/plan"
  } || age_rc=1
  if [ "$age_rc" -ne 0 ]; then
    rm -rf "$age_work"
    printf 'roundhouse: evidence aging could not read its records; nothing aged\n' >&2
    return 1
  fi
  if age_bad=$(awk -F'\t' '$1 == "X" { print $3; found = 1 } END { exit !found }' \
    "$age_work/plan"); then
    rm -rf "$age_work"
    printf 'roundhouse: evidence aging found %s unreadable day file(s) in journal/%s; nothing aged until they are repaired\n' \
      "$age_bad" "$age_host" >&2
    return 1
  fi
  age_summary=$(awk -F'\t' '
    $1 == "N" { n[$2] = $3; t[$2] = $4 }
    $1 == "D" && $2 ~ /\/journal\// { jd++ }
    $1 == "W" { jw++ }
    END {
      printf "journal/%s: %d of %d records past retention (%d day files removed, %d rewritten); ",
        host, n["journal"], t["journal"], jd, jw
      printf "alerts/%s: %d of %d removed; findings/%s: %d of %d removed",
        host, n["alerts"], t["alerts"], host, n["findings"], t["findings"]
    }' host="$age_host" "$age_work/plan")
  if [ "$age_dry" = true ]; then
    printf 'roundhouse: evidence aging (dry run, nothing changed): %s\n' "$age_summary"
    rm -rf "$age_work"
    return 0
  fi
  while IFS='	' read -r age_op age_path age_left; do
    [ "$age_op" = W ] || continue
    fleet_record_write "$age_path" "$age_left" || age_rc=1
  done <"$age_work/plan"
  awk -F'\t' '$1 == "D" { print $2 }' "$age_work/plan" | tr '\n' '\0' |
    xargs -0 rm -f || age_rc=1
  rm -rf "$age_work"
  printf 'roundhouse: evidence aging: %s\n' "$age_summary"
  return "$age_rc"
}

# --- §10.3 applied/<host>.yaml, the ownership record --------------------------

fleet_applied_path() {
  printf '%s/applied/%s.yaml\n' "$1" "$2"
}

fleet_applied_record() {
  # `fleet_applied_record STORE HOST ITEM DIGEST [AT]`. The ITEM ID ONLY,
  # never the scope that produced it: a host whose `groups:` list changes must
  # still see every previously applied item as a prune candidate and review it
  # by name (KEP-3659's failure mode).
  applied_file=$(fleet_applied_path "$1" "$2")
  fleet_record_write "$applied_file" \
    "$(fleet_record_read "$applied_file" '{}' | jq -c \
      --arg item "$3" --arg digest "$4" --arg at "${5:-$(fleet_now)}" \
      '.items[$item] = {digest: $digest, at: $at}')"
}

fleet_applied_forget() {
  applied_file=$(fleet_applied_path "$1" "$2")
  [ -f "$applied_file" ] || return 0
  fleet_record_write "$applied_file" \
    "$(fleet_record_read "$applied_file" '{}' | jq -c --arg item "$3" 'del(.items[$item])')"
}

fleet_applied_digest() {
  fleet_record_read "$(fleet_applied_path "$1" "$2")" '{}' |
    jq -r --arg item "$3" '.items[$item].digest // empty'
}

fleet_applied_count() {
  fleet_record_read "$(fleet_applied_path "$1" "$2")" '{}' | jq -r '(.items // {}) | length'
}

fleet_ownership_action() {
  # §10.3's table, as one function with one answer per row.
  # `fleet_ownership_action IN_LAYERS IN_APPLIED ON_HOST DIGEST_MATCH`, each
  # yes/no.
  #
  # Row 2 (in layers, NOT in applied/, present on the host) is the one rev 1
  # omitted, and it is the state a HOST REINSTALL produces — also what a
  # hand-truncated applied/<host>.yaml produces, and these files are
  # hand-editable by design. Without it the nearest matching row is "never
  # touch it", which makes roundhouse permanently disown everything it
  # installed.
  case "$1 $2 $3 $4" in
    'yes no no '*) printf 'adopt\n' ;;
    'yes no yes yes') printf 'adopt-in-place\n' ;;
    'yes no yes no') printf 'adopt-in-place-review\n' ;;
    'yes yes yes yes') printf 'nothing\n' ;;
    'yes yes '*) printf 'changed\n' ;;
    'no yes '*) printf 'prune\n' ;;
    # Software that never appears in applied/<host>.yaml is not ours. This is
    # the row with a body count attached (Rancher Fleet #5406) and it is the
    # default, not an afterthought.
    *) printf 'untouched\n' ;;
  esac
}

fleet_removal_cap() {
  # `fleet_removal_cap REMOVALS APPLIED_COUNT MAX_PER_RUN MAX_FRACTION`.
  # Prints the effective cap; exit 0 within it, exit 75 over — and over the
  # cap the caller holds the ENTIRE removal set, not the excess.
  #
  # Both terms, whichever is SMALLER. The honest statement is that neither
  # catches a one-line deletion, and nothing should: that is a legitimate
  # edit, and its defence is apply-time review naming the item, not a cap.
  cap_effective=$(jq -rn --argjson applied "$2" --argjson per_run "$3" \
    --argjson fraction "$4" '[$per_run, ($applied * $fraction | floor)] | min')
  printf '%s\n' "$cap_effective"
  [ "$1" -le "$cap_effective" ] || return 75
}

# --- §10.4 findings (the alerts are lib/fleet-alerts.sh) ----------------------

fleet_prose_shorten_commit_ids() {
  prose_text=$1
  prose_store=$2
  while :; do
    prose_token=$(printf '%s' "$prose_text" |
      grep -oE '(^|[^A-Za-z0-9_])[0-9a-f]{40}([^A-Za-z0-9_]|$)' |
      grep -oE '[0-9a-f]{40}' | head -1 || true)
    [ -n "$prose_token" ] || break
    fleet_quote_is_content_address "$prose_token" "$prose_store" || break
    prose_short=${prose_token:0:12}
    prose_text=$(printf '%s\n' "$prose_text" | awk \
      -v token="$prose_token" -v replacement="commit[$prose_short]" '
      BEGIN { done = 0 }
      {
        line = $0
        if (!done) {
          pattern = "(^|[^A-Za-z0-9_])" token "([^A-Za-z0-9_]|$)"
          if (match(line, pattern)) {
            matched = substr(line, RSTART, RLENGTH)
            leading = (substr(matched, 1, 1) == substr(token, 1, 1)) ? 0 : 1
            token_start = RSTART + leading
            line = substr(line, 1, token_start - 1) replacement \
              substr(line, token_start + length(token))
            done = 1
          }
        }
        print line
      }')
  done
  printf '%s\n' "$prose_text"
}

fleet_finding_write() {
  # `fleet_finding_write STORE HOST SLUG SUMMARY [QUOTE]`. Host-keyed, and the
  # quote passes the same floor as everything else that replicates.
  finding_summary=$(fleet_prose_shorten_commit_ids "$4" "$1")
  finding_quote=$(fleet_prose_shorten_commit_ids "${5:-}" "$1")
  fleet_replicated_text_ok "$finding_summary" || return 1
  [ "$#" -lt 5 ] || fleet_replicated_text_ok "$finding_quote" || return 1
  fleet_record_write "$1/findings/$2/$(fleet_record_stamp)-$3.yaml" \
    "$(jq -cn --arg host "$2" --arg summary "$finding_summary" --arg quote "$finding_quote" \
      --arg at "$(fleet_now)" \
      '{host: $host, summary: $summary,
        quote: (if $quote == "" then null else $quote end), at: $at}')"
}

# --- §10.2 proposals and unanimity promotion ----------------------------------

fleet_proposal_unanimous() {
  # `fleet_proposal_unanimous VALUES_JSON` over `[{host, value}]` for EVERY
  # enrolled host. Unanimity is the bar: 3-of-5 is normal curation for this
  # fleet (141 vs 58 standalone skills is intent, not drift) and produces no
  # proposal and no alert. A host that does not carry the item at all is not
  # agreement, so it breaks unanimity rather than being skipped.
  printf '%s\n' "$1" | jq -e '
    length > 1 and
    all(.[]; .value != null) and
    ([.[].value] | unique | length) == 1' >/dev/null 2>&1
}

fleet_proposal_write() {
  # `fleet_proposal_write STORE SLUG ITEM VALUE_JSON TO BY EVIDENCE FROM...`.
  # Content-named, so re-seeding UPSERTS the same path and never removes.
  # Ignoring a proposal does nothing; accepting it is `fleet-accept <slug>` or
  # a human doing the two edits.
  proposal_store=$1
  proposal_slug=$2
  proposal_item=$3
  proposal_value=$4
  proposal_to=$5
  proposal_by=$6
  proposal_evidence=$7
  shift 7
  fleet_replicated_text_ok "$proposal_evidence" || return 1
  fleet_record_write "$proposal_store/proposals/$proposal_slug.yaml" \
    "$(jq -cn --arg item "$proposal_item" --argjson value "$proposal_value" \
      --arg to "$proposal_to" --arg by "$proposal_by" \
      --arg evidence "$proposal_evidence" --arg at "$(fleet_now)" --args \
      '{proposes: "move", item: $item, value: $value, from: $ARGS.positional,
        to: $to, evidence: $evidence, by: $by, at: $at}' "$@")"
}

# --- §9.1 lineage: rename AND retirement --------------------------------------

fleet_lineage_write() {
  # `fleet_lineage_write STORE EVENT FROM BY [TO] [NOTE]`, event `renamed` or
  # `retired`. A retirement carries no `to`: if the name is ever reused for a
  # different machine that is a human decision, and this file is what they
  # read first.
  case $2 in
    renamed | retired) ;;
    *) return 1 ;;
  esac
  [ "$2" != renamed ] || [ -n "${5:-}" ] || return 1
  [ -z "${6:-}" ] || fleet_replicated_text_ok "$6" || return 1
  fleet_record_write "$1/lineage/$(date -u +%s)-$3.yaml" \
    "$(jq -cn --arg event "$2" --arg from "$3" --arg by "$4" \
      --arg to "${5:-}" --arg note "${6:-}" --arg at "$(fleet_now)" \
      '{event: $event, from: $from, to: (if $to == "" then null else $to end),
        at: $at, by: $by, note: (if $note == "" then null else $note end)}')"
}

fleet_lineage_current() {
  # Follow a rename chain to the name in use today, or report the retirement.
  # Chains are transitive because a machine can be renamed twice, and the
  # second rename must not orphan the first name's records.
  lineage_name=$2
  lineage_seen=0
  while [ "$lineage_seen" -lt 32 ]; do
    lineage_next=$(fleet_lineage_events "$1" |
      jq -r --arg from "$lineage_name" \
        'select(.from == $from) | if .event == "retired" then "retired" else .to end' |
      tail -1)
    [ -n "$lineage_next" ] || break
    [ "$lineage_next" != retired ] || {
      printf 'retired\n'
      return 0
    }
    lineage_name=$lineage_next
    lineage_seen=$((lineage_seen + 1))
  done
  printf '%s\n' "$lineage_name"
}

fleet_lineage_events() (
  LC_ALL=C
  [ -d "$1/lineage" ] || return 0
  for lineage_file in "$1"/lineage/*.yaml; do
    [ -f "$lineage_file" ] || continue
    yq -o=json -I=0 '.' "$lineage_file"
  done
)

# --- §10.5 upstream freshness -------------------------------------------------

fleet_upstream_write() {
  # `fleet_upstream_write STORE ID HOST RESULT`. One file per host per
  # upstream, so the last shared mutable path in the system is gone: no lease,
  # no CAS, no TTL, no discard rule, nothing to contend over.
  fleet_upstream_id_valid "$2" || {
    printf 'roundhouse: refusing unsafe upstream id: %s\n' "$2" >&2
    return 1
  }
  fleet_record_write "$1/upstreams/$2/$3.yaml" \
    "$(jq -cn --arg at "$(fleet_now)" --arg result "$4" \
      '{updated_at: $at, result: $result}')"
}

fleet_upstream_freshness() (
  # max(updated_at) across the directory. Jitter is the coordination
  # primitive; nothing here takes a turn.
  LC_ALL=C
  [ -d "$1/upstreams/$2" ] || return 0
  for upstream_file in "$1/upstreams/$2"/*.yaml; do
    [ -f "$upstream_file" ] || continue
    yq -r '.updated_at // ""' "$upstream_file"
  done | grep -v '^$' | sort | tail -1
)

# --- §5 policy, read from the store at the reviewed ref -----------------------

fleet_policy_defaults() {
  # The fallback, and the ONLY fallback: used when the store has no record of
  # a policy value at all. Deliberately not a host-local config read —
  # deleting `canary_group` or zeroing `canary_wait_hours` in a file on the
  # machine being gated must not weaken the gate.
  cat <<'EOF'
fast_interval_minutes 20
fast_jitter_minutes 5
cadence_hours 12
jitter_minutes 90
canary_group canary
canary_wait_hours 24
max_removals_per_run 5
max_removal_fraction 0.25
EOF
}

fleet_policy_get() {
  # `fleet_policy_get FOLD KEY`. FOLD is the folded desired state computed at
  # the reviewed ref R — policy is desired state like everything else, which
  # is what makes it reviewable, signed and fleet-wide rather than a knob on
  # the box it governs. The caller supplies the fold, so this unit stays free
  # of jj.
  policy_value=$(printf '%s\n' "$1" | jq -r --arg k "$2" '.policy[$k] // empty')
  [ -z "$policy_value" ] || {
    printf '%s\n' "$policy_value"
    return
  }
  fleet_policy_defaults | awk -v key="$2" '$1 == key { print $2; found = 1 }
    END { exit(found ? 0 : 1) }'
}

fleet_policy_int() {
  # `fleet_policy_int FOLD KEY` — a policy number as a FLOORED INTEGER safe to
  # feed `$(( ))`. The scheduling, jitter and stale-lock arithmetic does bare
  # `$(( $(fleet_policy_get …) … ))`, and a signed non-integer edit
  # (`cadence_hours: 12.0`, a realistic digest-perturbing value already on
  # record) crashed bash with an undocumented exit 1 — outside the run's hold
  # vocabulary, no alert, on every host at the next lock/jitter read. jq floors
  # a real number and rejects a non-number, so a garbage value degrades to the
  # built-in default (itself always a valid integer) rather than taking the run
  # down. Same jq-floor discipline `fleet_removal_cap` already uses.
  policy_int_val=$(fleet_policy_get "$1" "$2" |
    jq -r 'numbers | floor' 2>/dev/null | head -1)
  [ -n "$policy_int_val" ] || policy_int_val=$(fleet_policy_defaults |
    awk -v key="$2" '$1 == key { print $2; exit }' |
    jq -r 'numbers | floor' 2>/dev/null | head -1)
  printf '%s\n' "${policy_int_val:-0}"
}

# --- §10.1 the canary gate, with its liveness term ----------------------------

fleet_canary_gate() {
  # `fleet_canary_gate STORE ITEM DIGEST WAIT_HOURS NOW CANARY...`. A
  # non-canary host applies item X at digest D only when, for SOME canary c:
  #
  #   1. journal/c/ carries `outcome: applied` OR `outcome: satisfied` for
  #      {X, D}, at least canary_wait_hours ago, and
  #   2. no LATER record for X from c with `outcome: held` or `reverted`, and
  #   3. c has published SOME record — any item, or an `alive` heartbeat —
  #      dated at or after applied_at + canary_wait_hours.
  #
  # `satisfied` counts in condition 1 and `held` does not, and that asymmetry
  # is the whole point. An item the canary resolved and had nothing to do about
  # (B-3: no state-alignment verb for its category) can never produce an
  # `applied` record on any host — so gating downstream on one deadlocked the
  # item forever, on every host, with no safety bought: downstream will no-op
  # identically. An item the canary tried and COULD NOT apply, or that a gate
  # refused, still journals `held` and still blocks — a genuine apply failure
  # must never read as evidence of success.
  #
  # Condition 3 closes a lie by omission: a canary that applies an item, is
  # wrecked by it and stops journaling satisfies (1) and (2), and so does a
  # canary that went publication-silent because of an unrelated conflict —
  # which is precisely the state §8.4 mandates. Two forms of silence were
  # reading as a pass. With the liveness term a silenced canary BLOCKS
  # promotion instead of permitting it on stale evidence.
  #
  # Time comes from journal `at` fields, never commit timestamps. Attribution
  # is real because of §7.3: the commit introducing a record under journal/c/
  # must verify as c.
  canary_store=$1
  canary_item=$2
  canary_digest=$3
  canary_wait=$4
  canary_now=$5
  shift 5
  for canary_host in "$@"; do
    # Read the canary's journal to a file and CHECK IT PARSED. A conflicted
    # day-file makes the read partial; condition 2 is a claim about the WHOLE
    # journal, so a canary this host cannot fully read is not allowed to satisfy
    # the gate — skip it and fall through to the default hold, never promote on
    # a partial that may be hiding the withdrawal.
    canary_ev=$(mktemp "${TMPDIR:-/tmp}/roundhouse-canary.XXXXXX") || return 75
    if ! fleet_journal_entries "$canary_store" "$canary_host" \
      >"$canary_ev" 2>/dev/null; then
      rm -f "$canary_ev"
      continue
    fi
    jq -es --arg item "$canary_item" --arg digest "$canary_digest" \
      --argjson wait "$canary_wait" --arg now "$canary_now" '
        ($now | fromdateiso8601) as $now_epoch |
        ($wait * 3600) as $wait_seconds |
        [.[] | select(.item == $item and .digest == $digest and
          (.outcome == "applied" or .outcome == "satisfied"))] as $applied |
        ($applied | map(.at | fromdateiso8601) | min) as $applied_epoch |
        $applied_epoch != null and
        ($applied_epoch + $wait_seconds) <= $now_epoch and
        # (2) nothing later withdrew it
        ([.[] | select(.item == $item and
          (.outcome == "held" or .outcome == "reverted")) |
          (.at | fromdateiso8601) | select(. > $applied_epoch)] | length) == 0 and
        # (3) the canary was still publishing after the wait elapsed
        ([.[] | (.at | fromdateiso8601) |
          select(. >= ($applied_epoch + $wait_seconds))] | length) > 0
        ' <"$canary_ev" >/dev/null 2>&1 && {
      rm -f "$canary_ev"
      return 0
    }
    rm -f "$canary_ev"
  done
  return 75
}
