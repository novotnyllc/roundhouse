# roundhouse — the run driver: two cadences, one convergence.
#
# §6, §6.1, §8 and §10 of docs/specs/2026-08-06-dsc-storage-design-v2.md. This
# unit is the integration point and owns no new doctrine of its own: the fold,
# the records, the signature gate, the reconcile runbook and the resolution
# ladder each already decided their own question, and what is left is the ORDER
# they are asked in. That order is the design:
#
#   poll floor -> fetch -> step 0 -> promote gate -> fold at R per head ->
#   hold set -> review -> verdict -> apply -> applied/ -> journal -> publish
#
# Two rules bind every line below and neither is stylistic:
#
#   The bare token `main` never appears in a revset (§8.1). Every read goes
#   through lib/fleet-vcs.sh, which is where that rule is enforced once.
#
#   NEVER `jj new -m ''` after a push. An undescribed commit that becomes an
#   ancestor of the bookmark refuses to push forever; `fleet_vcs_publish`'s
#   `jj new <target>` is the only post-push working-copy move in the system.
#
# Sourced by scripts/roundhouse; carries definitions only.
# shellcheck shell=bash

# --- §7.6 the verdict, host-local and never replicated ------------------------

fleet_run_state_dir() {
  # store.run/ — verdicts, the nudge memo, the starting operation id. The
  # judges named a fleet-writable verdict as the one thing that must not
  # survive: it puts a consent-shaped artifact on a shared surface and then
  # needs prose to say it is not one. The canary gate reads journal/ instead.
  fleet_instance_path store.run
}

fleet_run_verdict_path() {
  printf '%s/verdicts/%s.yaml\n' "$(fleet_run_state_dir)" "$1"
}

fleet_run_verdict_write() {
  # fleet_run_verdict_write ITEM DIGEST REASON [REVIEWER] [VERDICT]
  #
  # ONE writer for both verdicts. The run writes `pass` as it applies; a human
  # writes either through `fleet-review`. Keeping them one record shape is what
  # lets the run's hold guard below read a human's decision without a second
  # vocabulary — and a `hold` the run could not see would be decoration.
  #
  # Inside the run loop the write is QUEUED (fleet_run_batch_open) and lands
  # with the rest at the flush — except where the destination is a symlink,
  # which is refused here and now exactly as fleet_record_write refuses it.
  if [ -n "${fleet_run_batch:-}" ] &&
    [ ! -L "$fleet_run_batch_verdict_dir/$1.yaml" ]; then
    # decided_at as epoch seconds, kept without a `date` process per item
    # (the batch's base instant plus the shell's SECONDS); the flush renders
    # it in fleet_now's format.
    printf '%s\n' "$1$fleet_run_sep$2$fleet_run_sep$3$fleet_run_sep${4:-agent}$fleet_run_sep${5:-pass}$fleet_run_sep$((fleet_run_batch_epoch + SECONDS - fleet_run_batch_seconds))" \
      >>"$fleet_run_batch/verdicts"
    return 0
  fi
  fleet_record_write "$(fleet_run_verdict_path "$1")" \
    "$(jq -cn --arg item "$1" --arg digest "$2" --arg reason "$3" \
      --arg reviewer "${4:-agent}" --arg verdict "${5:-pass}" \
      --arg at "$(fleet_now)" \
      '{item:$item,verdict:$verdict,reason:$reason,digest:$digest,
        reviewer:$reviewer,decided_at:$at}')"
}

fleet_run_verdict_digest() {
  fleet_record_read "$(fleet_run_verdict_path "$1")" '{}' |
    jq -r 'select(.verdict == "pass") | .digest // empty'
}

fleet_run_verdict_held() {
  # fleet_run_verdict_held ITEM DIGEST — a hold BOUND TO THIS DIGEST. Keying on
  # the digest is the whole point: a hold is a judgement about a value, so the
  # next edit to that item is a new value that has never been reviewed and must
  # not inherit the refusal. An unkeyed hold is a permanent one nobody
  # remembers setting.
  [ "$(fleet_record_read "$(fleet_run_verdict_path "$1")" '{}' |
    jq -r 'select(.verdict == "hold") | .digest // empty')" = "$2" ]
}

# --- the apply loop's bookkeeping, read once and written once -----------------
#
# The loop below reviews every item every run, and its bookkeeping used to cost
# more than the applies: per item, two reads of applied/<h>.yaml, a read of the
# verdict file, a yq pass over EVERY day of this host's journal (the §10.8
# revert check), then a rewrite of the verdict, of applied/<h>.yaml and of the
# day's journal file — which on a busy host is thousands of entries, re-parsed
# and re-written once per item. Measured: ~2.5 s per item, ~25 min for 550.
#
# The answers are the same when read once, because each item's lookups only
# ever concern that item: nothing the loop writes for item X is read for any
# other item. (The one cross-item read, the hook gate's look at
# `plugins.<p>` in applied/, is handled by flushing before any `hooks.` item
# applies.) So the loop reads a precomputed plan and queues its writes, and the
# queues land in one read-modify-write per file, in the order they were queued.

fleet_run_sep=$(printf '\037')

fleet_run_item_plan() {
  # fleet_run_item_plan STORE HOST FOLD VERDICTS SIGHOLDS -> one line per
  # verdict line:
  #   VERDICT US ITEM US DIGEST US VALUE US APPLIED-DIGEST US REVIEW-HELD US
  #   REVERT US STATE US HOLD
  # (US = \037, which no compact JSON value and no item id carries). Each field
  # is what the per-item call it replaces answers for that item:
  #   VALUE           fleet_item_value FOLD ITEM
  #   APPLIED-DIGEST  fleet_applied_digest STORE HOST ITEM
  #   REVIEW-HELD     1 when fleet_run_verdict_held ITEM DIGEST
  #   REVERT          1 when fleet_run_is_revert STORE HOST ITEM DIGEST
  #   STATE           fleet_run_state_of VALUE (a value whose state would print
  #                   on more than one line is carried JSON-quoted: it is
  #                   neither `enabled` nor `disabled` either way)
  #   HOLD            the SIGHOLDS lookup, `awk '$1 == item { $1 = ""; print;
  #                   exit }'`, as of now (the loop re-reads once it adds one)
  # Any batch read that fails falls back to those very calls for every item.
  plan_tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-plan.XXXXXX") || return 1
  awk 'NF { print $2 "\t" (NF > 2 ? $3 : "") "\t" $1 }' "$4" >"$plan_tmp/items"
  # The hold lookup's own awk, over the whole file at once: the FIRST line
  # naming an item wins, rebuilt by `$1 = ""` exactly as the lookup prints it.
  awk -v us="$fleet_run_sep" '!($1 in seen) { seen[$1] = 1; k = $1; $1 = ""; print k us $0 }' \
    "$5" >"$plan_tmp/sigholds" 2>/dev/null || : >"$plan_tmp/sigholds"
  plan_ok=true
  # Values: fleet_item_value's split and `// empty`, once over the fold.
  printf '%s\n' "$3" | jq -r --rawfile items "$plan_tmp/items" \
    "$fleet_item_value_jq"'
    . as $doc |
    $items | split("\n")[] | select(. != "") | split("\t")[0] as $item |
    [$item | fleet_item_value($doc)] |
    (if length > 0 then (.[0] | if type == "object" then
        (if has("state") then .state else "enabled" end) else . end |
        if type == "string" and (explode | all(. >= 32)) then . else tojson end)
      else "" end) as $state |
    "\($item)\t\(if length > 0 then (.[0] | tojson) else "" end)\t\($state)"' \
    >"$plan_tmp/values" 2>/dev/null || plan_ok=false
  # applied/<h>.yaml, read once.
  [ "$plan_ok" = false ] ||
    fleet_record_read "$(fleet_applied_path "$1" "$2")" '{}' |
    jq -r '(.items // {}) | to_entries[] | select(.value | type == "object") |
      "\(.key)\t\(.value.digest // "" | tostring)"' >"$plan_tmp/applied" 2>/dev/null ||
    plan_ok=false
  # Every verdict file the plan's items have, read in one yq. A missing file
  # is no record; an unreadable one is not a hold, exactly as the per-item read
  # answered, so a failed batch falls back rather than guessing which file.
  : >"$plan_tmp/verdict-files"
  # fleet_run_verdict_path's answer, with the state directory resolved once.
  plan_vdir=$(fleet_run_state_dir)/verdicts
  while IFS='	' read -r plan_item plan_digest plan_verdict; do
    [ ! -f "$plan_vdir/$plan_item.yaml" ] ||
      printf '%s\t%s\n' "$plan_vdir/$plan_item.yaml" "$plan_item" >>"$plan_tmp/verdict-files"
  done <"$plan_tmp/items"
  : >"$plan_tmp/holds"
  if [ "$plan_ok" = true ] && [ -s "$plan_tmp/verdict-files" ]; then
    # xargs execs yq, bypassing the function: see select_mikefarah_yq.
    cut -f1 "$plan_tmp/verdict-files" | tr '\n' '\0' |
      xargs -0 "${ROUNDHOUSE_YQ:-yq}" -o=json -I=0 '{"f": filename, "v": (.verdict // ""), "d": (.digest // "")}' \
        >"$plan_tmp/verdicts.json" 2>/dev/null || plan_ok=false
    [ "$plan_ok" = false ] ||
      jq -r 'select(.v == "hold" and .d != "") | "\(.f)\t\(.d | tostring)"' \
        <"$plan_tmp/verdicts.json" >"$plan_tmp/holds" 2>/dev/null || plan_ok=false
  fi
  # This host's own journal, every day file in the order the revert check
  # reads it, as `<item>\t<outcome> <digest>` — one yq per day, not per item.
  : >"$plan_tmp/outcomes"
  if [ "$plan_ok" = true ] && [ -d "$1/journal/$2" ]; then
    if [ -z "$(find "$1/journal/$2" -mindepth 2 -type f -name '*.yaml' 2>/dev/null |
      head -1)" ] && [ -z "$(find "$1/journal/$2" -maxdepth 1 -type f -name '.*.yaml' \
      2>/dev/null | head -1)" ]; then
      # Every day file is directly under the host's directory, so the cached
      # day-by-day parse (fleet_run_journal_entries) reads the same files in
      # the same order.
      fleet_run_journal_entries "$1" "$2" 2>/dev/null | jq -r '
        select(type == "object" and (.item | type) == "string") |
        try (.item + "\t" + ((.outcome // "-") + " " + (.digest // "-"))) catch empty' \
        >"$plan_tmp/outcomes" 2>/dev/null || :
    else
      find "$1/journal/$2" -type f -name '*.yaml' | LC_ALL=C sort |
        while IFS= read -r plan_day; do
          yq -r '.[] | select((.item | tag) == "!!str") |
            .item + "\t" + ((.outcome // "-") + " " + (.digest // "-"))' \
            "$plan_day" 2>/dev/null || true
        done >"$plan_tmp/outcomes"
    fi
  fi
  if [ "$plan_ok" = true ]; then
    LC_ALL=C awk -F'\t' -v us="$fleet_run_sep" '
      FILENAME == ARGV[1] { value[$1] = $2; state[$1] = $3; next }
      FILENAME == ARGV[2] { applied[$1] = $2; next }
      FILENAME == ARGV[3] { vfile[$1] = $2; next }
      FILENAME == ARGV[4] {
        # The per-item read printed one line per hold document carrying a
        # digest and compared the whole output: a hold only when exactly one.
        if ($1 in vfile) { holds[vfile[$1]]++; held[vfile[$1]] = $2 }
        next
      }
      FILENAME == ARGV[6] { split($0, sh, us); hold[sh[1]] = substr($0, length(sh[1]) + 2); next }
      FILENAME == ARGV[5] {
        # fleet_vcs_revert_signature, per item, over the same ordered lines.
        split($2, od, " ")
        if (od[1] == "applied") { cur[$1] = od[2]; app[$1, od[2]] = 1 }
        else if (od[1] == "reverted") cur[$1] = ""
        next
      }
      {
        item = $1; digest = $2
        rh = ((item in held) && holds[item] == 1 && held[item] == digest) ? 1 : 0
        rv = (((item, digest) in app) && cur[item] != digest) ? 1 : 0
        print $3 us item us digest us value[item] us applied[item] us rh us rv us state[item] us hold[item]
      }
    ' "$plan_tmp/values" "$plan_tmp/applied" "$plan_tmp/verdict-files" \
      "$plan_tmp/holds" "$plan_tmp/outcomes" "$plan_tmp/sigholds" "$plan_tmp/items"
  else
    # The loop's own read of the verdict list, then each per-item call.
    while read -r plan_verdict plan_item plan_digest; do
      [ -n "${plan_verdict:-}" ] || continue
      plan_rh=0
      plan_rv=0
      if [ -n "${plan_digest:-}" ]; then
        ! fleet_run_verdict_held "$plan_item" "$plan_digest" || plan_rh=1
        ! fleet_run_is_revert "$1" "$2" "$plan_item" "$plan_digest" || plan_rv=1
      fi
      plan_value=$(fleet_item_value "$3" "$plan_item" 2>/dev/null) || plan_value=
      # fleet_run_state_of's answer, carried the way the batch carries it.
      plan_state=$(printf '%s\n' "$plan_value" | jq -r '
        if type == "object" then (if has("state") then .state else "enabled" end) else . end |
        if type == "string" and (explode | all(. >= 32)) then . else tojson end' 2>/dev/null) ||
        plan_state=
      printf '%s\n' "$plan_verdict$fleet_run_sep${plan_item:-}$fleet_run_sep${plan_digest:-}$fleet_run_sep$plan_value$fleet_run_sep$(fleet_applied_digest "$1" "$2" "${plan_item:-}")$fleet_run_sep$plan_rh$fleet_run_sep$plan_rv$fleet_run_sep$plan_state$fleet_run_sep$(awk -v item="${plan_item:-}" '$1 == item { $1 = ""; print; exit }' "$5")"
    done <"$4"
  fi
  rm -rf "$plan_tmp"
}

fleet_run_records_batch() {
  # fleet_run_records_batch < `PATH US JSON` lines — the files fleet_record_write
  # PATH JSON would write, line after line, in a constant number of processes:
  # the JSON objects go through ONE `yq -P -p=json -o=yaml` as a multi-document
  # stream, split back at its `---` separators (a document's own lines are
  # never a bare `---`: yq indents block scalars and quotes flow ones), staged
  # owner-only inside each destination directory and installed by rename.
  #
  # Anything the batch cannot account for takes fleet_record_write itself: a
  # document count that does not match, a staging directory it cannot make —
  # and a destination that is a symlink, which fleet_record_write refuses by
  # exiting, so the lines before it land first and the refusal then happens
  # exactly where the one-by-one writes would have reached it.
  frb_in=$(mktemp "${TMPDIR:-/tmp}/roundhouse-records.XXXXXX") || return 1
  cat >"$frb_in"
  frb_first_link=0
  frb_n=0
  while IFS="$fleet_run_sep" read -r frb_path frb_json; do
    frb_n=$((frb_n + 1))
    if [ -L "$frb_path" ]; then
      frb_first_link=$frb_n
      break
    fi
  done <"$frb_in"
  if [ "$frb_first_link" -gt 0 ]; then
    head -n "$((frb_first_link - 1))" "$frb_in" >"$frb_in.head"
    sed -n "${frb_first_link},\$p" "$frb_in" >"$frb_in.tail"
    frb_tail=$frb_in.tail
    [ ! -s "$frb_in.head" ] || fleet_run_records_install "$frb_in.head"
    rm -f "$frb_in" "$frb_in.head"
    # The refusal (and whatever would follow it) is the one-item writer's.
    fleet_run_records_slow "$frb_tail"
    rm -f "$frb_tail"
    return 0
  fi
  fleet_run_records_install "$frb_in"
  rm -f "$frb_in"
}

fleet_run_records_install() {
  # fleet_run_records_install FILE — the batch proper, over `PATH US JSON`
  # lines none of whose destinations is a symlink.
  frb_inst=$1
  frb_ok=true
  frb_stage_root=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-records.XXXXXX") || frb_ok=false
  # One staging directory per destination directory, inside it, so the
  # install is a same-filesystem rename — named `.roundhouse.*`, like
  # safe_output's own temporaries, which the store's .gitignore keeps out of
  # any snapshot should a run die mid-write.
  if [ "$frb_ok" = true ]; then
    : >"$frb_stage_root/targets"
    : >"$frb_stage_root/stages"
    while IFS="$fleet_run_sep" read -r frb_path frb_json; do
      case $frb_path in */*) frb_dir=${frb_path%/*} ;; *) frb_dir=. ;; esac
      frb_stage=$(LC_ALL=C awk -F'\t' -v d="$frb_dir" '$1 == d { print $2; exit }' \
        "$frb_stage_root/stages")
      if [ -z "$frb_stage" ]; then
        mkdir -p "$frb_dir" && frb_stage=$(mktemp -d "$frb_dir/.roundhouse.batch.XXXXXX") ||
          { frb_ok=false; break; }
        printf '%s\t%s\n' "$frb_dir" "$frb_stage" >>"$frb_stage_root/stages"
      fi
      printf '%s\n' "$frb_stage/${frb_path##*/}" >>"$frb_stage_root/targets"
    done <"$frb_inst"
  fi
  if [ "$frb_ok" = true ]; then
    LC_ALL=C awk -v us="$fleet_run_sep" '{ i = index($0, us); print substr($0, i + 1) }' \
      "$frb_inst" | yq -P -p=json -o=yaml >"$frb_stage_root/docs" 2>/dev/null || frb_ok=false
  fi
  if [ "$frb_ok" = true ]; then
    (umask 077 && LC_ALL=C awk -v dir="$frb_stage_root" '
      FILENAME == ARGV[1] { name[FNR] = $0; n = FNR; next }
      FNR == 1 || $0 == "---" {
        if (out != "") close(out)
        if ($0 == "---") { d++; out = (d <= n ? name[d] : ""); next }
        d = 1; out = name[1]
      }
      out != "" { print > out }
      END { if (out != "") close(out); exit (d == n) ? 0 : 1 }
    ' "$frb_stage_root/targets" "$frb_stage_root/docs") || frb_ok=false
  fi
  if [ "$frb_ok" = true ]; then
    while IFS='	' read -r frb_dir frb_stage; do
      (cd "$frb_stage" && find . -type f -print0 |
        xargs -0 sh -c 'mv -f "$@" "$0"' "$frb_dir/") || frb_ok=false
    done <"$frb_stage_root/stages"
  fi
  if [ -f "$frb_stage_root/stages" ]; then
    while IFS='	' read -r frb_dir frb_stage; do
      rm -rf "$frb_stage"
    done <"$frb_stage_root/stages"
  fi
  rm -rf "$frb_stage_root"
  # A batch that did not complete is written again, one record at a time; a
  # record already installed is simply rewritten with the same bytes.
  [ "$frb_ok" = true ] || fleet_run_records_slow "$frb_inst"
}

fleet_run_records_slow() {
  while IFS="$fleet_run_sep" read -r frs_path frs_json; do
    [ -n "$frs_path" ] || continue
    fleet_record_write "$frs_path" "$frs_json" || :
  done <"$1"
}

fleet_run_flush_verdicts() {
  # The queued verdicts as fleet_run_verdict_write would have written them one
  # by one: the same JSON object, key for key, at the same path.
  jq -r -R --arg us "$fleet_run_sep" --arg dir "$fleet_run_batch_verdict_dir" '
    split($us) |
    "\($dir)/\(.[0]).yaml\($us)\({item: .[0], verdict: .[4], reason: .[2],
      digest: .[1], reviewer: .[3], decided_at: (.[5] | tonumber | todate)} | tojson)"' \
    <"$fleet_run_batch/verdicts" | fleet_run_records_batch
  : >"$fleet_run_batch/verdicts"
}

fleet_run_sha256_files() {
  # fleet_run_sha256_files FILE... -> one sha256 per line, in argument order,
  # from ONE process (sha256_stream's tool preference). Non-zero when the tool
  # is missing or did not answer for every file.
  [ "$#" -gt 0 ] || return 0
  if command -v sha256sum >/dev/null 2>&1; then
    fleet_run_sums=$(sha256sum "$@" 2>/dev/null) || return 1
    fleet_run_sums=$(printf '%s\n' "$fleet_run_sums" | awk '{ print tolower($1) }')
  elif command -v shasum >/dev/null 2>&1; then
    fleet_run_sums=$(shasum -a 256 "$@" 2>/dev/null) || return 1
    fleet_run_sums=$(printf '%s\n' "$fleet_run_sums" | awk '{ print tolower($1) }')
  else
    fleet_run_sums=$(openssl dgst -sha256 "$@" 2>/dev/null) || return 1
    fleet_run_sums=$(printf '%s\n' "$fleet_run_sums" | awk '{ print tolower($NF) }')
  fi
  [ "$(printf '%s\n' "$fleet_run_sums" | grep -c .)" -eq "$#" ] || return 1
  printf '%s\n' "$fleet_run_sums"
}

fleet_run_journal_entries() {
  # fleet_run_journal_entries STORE HOST — fleet_journal_entries' output AND
  # status (non-zero when a day file does not parse, and the entries that do
  # parse are still printed), with each day file's parse cached host-locally.
  #
  # The cache is CONTENT-ADDRESSED both ways: an entry is named
  # `<day>.<sha256 of the day file>.<sha256 of the parse>.jsonl`, so a changed
  # day file is a miss by construction, and an entry whose own bytes no longer
  # hash to its name (truncated, corrupted, edited) is a miss too — never an
  # answer. Only a successful parse is stored, by atomic rename; a cache that
  # cannot be hashed or written falls back to fleet_journal_entries itself.
  # A busy host's day file is thousands of entries and a yq parse of it costs
  # ~0.3 s, and the canary gate, the revert check and doctor each read every
  # day of every host they ask about.
  fleet_run_jstore=$1
  fleet_run_jhost=$2
  fleet_run_jdir="$1/journal/$2"
  [ -d "$fleet_run_jdir" ] || return 0
  fleet_run_jcache=$(fleet_run_state_dir)/journal-cache/$2
  set --
  for fleet_run_jfile in "$fleet_run_jdir"/*.yaml; do
    [ -f "$fleet_run_jfile" ] || continue
    set -- "$@" "$fleet_run_jfile"
  done
  [ "$#" -gt 0 ] || return 0
  if ! mkdir -p "$fleet_run_jcache" 2>/dev/null ||
    ! fleet_run_jsums=$(fleet_run_sha256_files "$@"); then
    fleet_journal_entries "$fleet_run_jstore" "$fleet_run_jhost"
    return
  fi
  # Every cache entry for a current day file, and the hash of its bytes, in
  # one process.
  fleet_run_jcands=
  fleet_run_jsums_left=$fleet_run_jsums
  for fleet_run_jfile in "$@"; do
    fleet_run_jsum=${fleet_run_jsums_left%%"
"*}
    fleet_run_jsums_left=${fleet_run_jsums_left#*"
"}
    for fleet_run_jcand in "$fleet_run_jcache/${fleet_run_jfile##*/}.$fleet_run_jsum".*.jsonl; do
      [ -f "$fleet_run_jcand" ] || continue
      fleet_run_jcands="$fleet_run_jcands$fleet_run_jcand
"
    done
  done
  fleet_run_jvalid=
  if [ -n "$fleet_run_jcands" ]; then
    set -f
    # shellcheck disable=SC2046 # one path per line (IFS is a newline here)
    fleet_run_jbodysums=$(IFS='
'; fleet_run_sha256_files $(printf '%s' "$fleet_run_jcands")) || fleet_run_jbodysums=
    set +f
    if [ -n "$fleet_run_jbodysums" ] &&
      fleet_run_jlist=$(mktemp "${TMPDIR:-/tmp}/roundhouse-jcache.XXXXXX"); then
      # Line N of the sums is the hash of candidate N; a candidate is valid
      # when the hash its name carries is the hash of its bytes.
      printf '%s\n' "$fleet_run_jbodysums" >"$fleet_run_jlist"
      fleet_run_jvalid=$(printf '%s' "$fleet_run_jcands" | LC_ALL=C awk '
          FILENAME == ARGV[1] { s[FNR] = $0; next }
          { f = $0; sub(/\.jsonl$/, "", f); sub(/.*\./, "", f)
            if (f == s[FNR]) print $0 }' "$fleet_run_jlist" -)
      rm -f "$fleet_run_jlist"
    fi
  fi
  fleet_run_jrc=0
  fleet_run_jkeep=
  fleet_run_jsums_left=$fleet_run_jsums
  for fleet_run_jfile in "$@"; do
    fleet_run_jsum=${fleet_run_jsums_left%%"
"*}
    fleet_run_jsums_left=${fleet_run_jsums_left#*"
"}
    fleet_run_jprefix=$fleet_run_jcache/${fleet_run_jfile##*/}.$fleet_run_jsum.
    fleet_run_jhit=$(printf '%s\n' "$fleet_run_jvalid" | grep -F -- "$fleet_run_jprefix" | head -1)
    # A concurrent reader (doctor runs unlocked) may prune an entry between
    # the check and the read; a read that fails to OPEN is a miss, never a gap.
    if [ -n "$fleet_run_jhit" ] && cat "$fleet_run_jhit" 2>/dev/null; then
      fleet_run_jkeep="$fleet_run_jkeep/${fleet_run_jhit##*/}/"
      continue
    fi
    fleet_run_jtmp=$(mktemp "$fleet_run_jcache/.parse.XXXXXX") || {
      yq -o=json -I=0 '(. // []) | .[]' "$fleet_run_jfile" 2>/dev/null || fleet_run_jrc=1
      continue
    }
    if yq -o=json -I=0 '(. // []) | .[]' "$fleet_run_jfile" >"$fleet_run_jtmp" 2>/dev/null; then
      cat "$fleet_run_jtmp"
      fleet_run_jbody=$(fleet_run_sha256_files "$fleet_run_jtmp") || fleet_run_jbody=
      if [ -n "$fleet_run_jbody" ] &&
        mv -f "$fleet_run_jtmp" "$fleet_run_jprefix$fleet_run_jbody.jsonl" 2>/dev/null; then
        fleet_run_jkeep="$fleet_run_jkeep/${fleet_run_jprefix##*/}$fleet_run_jbody.jsonl/"
      else
        rm -f "$fleet_run_jtmp"
      fi
    else
      cat "$fleet_run_jtmp"
      rm -f "$fleet_run_jtmp"
      fleet_run_jrc=1
    fi
  done
  # Drop every entry this read did not use: a stale parse, a corrupted one.
  for fleet_run_jold in "$fleet_run_jcache"/*.jsonl; do
    [ -f "$fleet_run_jold" ] || continue
    case $fleet_run_jkeep in
      */"${fleet_run_jold##*/}"/*) ;;
      *) rm -f "$fleet_run_jold" ;;
    esac
  done
  return "$fleet_run_jrc"
}

fleet_run_canary_passing() {
  # fleet_run_canary_passing STORE WAIT NOW PLAN CANARY... -> `<item>US<digest>`
  # for every converging plan item fleet_canary_gate would pass. One read of
  # each canary's journal and one evaluation for every item, instead of every
  # canary's whole journal re-read per item.
  #
  # The predicate is fleet_canary_gate's, term for term, including where it
  # ERRS: jq exits non-zero, which the gate reads as "no evidence", when an
  # entry it inspects is not indexable or carries an `at` that is not
  # ISO8601. Each `try … catch` below is one of those errors, scoped to exactly
  # the entries the gate's own expression touches for that item. A canary
  # whose journal does not fully parse is skipped, as the gate skips it.
  fleet_run_cp_store=$1
  fleet_run_cp_wait=$2
  fleet_run_cp_now=$3
  fleet_run_cp_pairs=$(mktemp "${TMPDIR:-/tmp}/roundhouse-canary.XXXXXX") || return 0
  LC_ALL=C awk -F"$fleet_run_sep" '$1 == "converge" && $3 != "" { print $2 "\t" $3 }' \
    "$4" >"$fleet_run_cp_pairs"
  shift 4
  for fleet_run_cp_host in "$@"; do
    fleet_run_cp_entries=$(mktemp "${TMPDIR:-/tmp}/roundhouse-canary.XXXXXX") || continue
    if fleet_run_journal_entries "$fleet_run_cp_store" "$fleet_run_cp_host" \
      >"$fleet_run_cp_entries" 2>/dev/null; then
      jq -s -r --rawfile pairs "$fleet_run_cp_pairs" --arg us "$fleet_run_sep" \
        --argjson wait "$fleet_run_cp_wait" --arg now "$fleet_run_cp_now" '
        ($now | fromdateiso8601) as $now_epoch |
        ($wait * 3600) as $ws |
        . as $all |
        # `.item` on a string, number, boolean or array errs for every item.
        all($all[]; type == "object" or type == "null") as $indexable |
        # Condition 3 parses EVERY entry`s `at`; one failure errs the gate.
        (try ([$all[] | .at | fromdateiso8601] | max) catch null) as $latest |
        (reduce ($all[] | objects | select(.item | type == "string")) as $e
          ({}; .[$e.item] += [$e])) as $by_item |
        $pairs | split("\n")[] | select(. != "") | split("\t") as [$item, $digest] |
        ($by_item[$item] // []) as $mine |
        select($indexable) |
        # As the gate asks it: the latest withdrawal, then the first
        # identity-less evidence after it (the current clean run).
        (try ([$mine[] | select(.outcome == "held" or .outcome == "reverted") |
            .at | fromdateiso8601] | max) catch "error") as $withdrawn |
        select($withdrawn != "error") |
        (try ([$mine[] | select(.digest == $digest and (.identity // "") == "" and
            (.outcome == "applied" or .outcome == "satisfied")) |
            .at | fromdateiso8601 | select($withdrawn == null or . > $withdrawn)] |
            min) catch "error") as $applied_epoch |
        select($applied_epoch != "error" and $applied_epoch != null) |
        select(($applied_epoch + $ws) <= $now_epoch) |
        select($latest != null and $latest >= ($applied_epoch + $ws)) |
        "\($item)\($us)\($digest)"' <"$fleet_run_cp_entries" 2>/dev/null || :
    fi
    rm -f "$fleet_run_cp_entries"
  done | LC_ALL=C sort -u
  rm -f "$fleet_run_cp_pairs"
}

fleet_run_batch_open() {
  # fleet_run_batch_open DIR — from here until fleet_run_batch_close, the
  # loop's verdict, applied/ and journal writes queue under DIR.
  fleet_run_batch=$1
  fleet_run_batch_verdict_dir=$(fleet_run_state_dir)/verdicts
  fleet_run_batch_epoch=$(date -u +%s)
  fleet_run_batch_seconds=$SECONDS
  mkdir -p "$fleet_run_batch"
  : >"$fleet_run_batch/verdicts"
  : >"$fleet_run_batch/applied"
  : >"$fleet_run_batch/journal"
}

fleet_run_batch_close() {
  fleet_run_batch_flush "$@"
  fleet_run_batch=
}

fleet_run_journal_queue() {
  # fleet_run_journal_queue STORE HOST ITEM DIGEST OUTCOME AT — the loop's
  # `{item, digest, outcome, at}` journal entry; appended now when no batch is
  # open, exactly as before.
  if [ -n "${fleet_run_batch:-}" ]; then
    printf '%s\n' "$3$fleet_run_sep$4$fleet_run_sep$5$fleet_run_sep$6" \
      >>"$fleet_run_batch/journal"
    return 0
  fi
  fleet_journal_append "$1" "$2" \
    "$(jq -cn --arg item "$3" --arg d "$4" --arg o "$5" --arg at "$6" \
      '{item:$item,digest:$d,outcome:$o,at:$at}')"
}

fleet_run_applied_queue() {
  # fleet_run_applied_queue STORE HOST ITEM DIGEST AT
  if [ -n "${fleet_run_batch:-}" ]; then
    printf '%s\n' "$3$fleet_run_sep$4$fleet_run_sep$5" >>"$fleet_run_batch/applied"
    return 0
  fi
  fleet_applied_record "$1" "$2" "$3" "$4" "$5"
}

fleet_run_batch_flush() {
  # fleet_run_batch_flush STORE HOST [applied-only] — land every queued
  # write: verdicts, then applied/, then the journal (the per-item order), each
  # file read and written ONCE. The results are the files the per-item writers
  # would have produced in sequence. `applied-only` lands just applied/, for a
  # reader of it mid-loop.
  [ -n "${fleet_run_batch:-}" ] || return 0
  [ "${3:-}" = applied-only ] || [ ! -s "$fleet_run_batch/verdicts" ] ||
    fleet_run_flush_verdicts
  if [ -s "$fleet_run_batch/applied" ]; then
    fleet_run_flush_file=$(fleet_applied_path "$1" "$2")
    if ! fleet_record_write "$fleet_run_flush_file" \
      "$(fleet_record_read "$fleet_run_flush_file" '{}' |
        jq -c --rawfile q "$fleet_run_batch/applied" --arg us "$fleet_run_sep" '
          reduce ($q | split("\n")[] | select(. != "") | split($us)) as $e (.;
            .items[$e[0]] = {digest: $e[1], at: $e[2]})')"; then
      # The per-item writer's failure, per item: loud and narrow, never fatal.
      while IFS="$fleet_run_sep" read -r fleet_run_flush_item fleet_run_flush_rest; do
        printf 'roundhouse: could not record %s in applied/%s.yaml; the item is applied but unowned\n' \
          "$fleet_run_flush_item" "$2" >&2
        # Through the pass's ledger when there is one: the item was already
        # noted `checked`, so a bare write would be swept at the end of the pass.
        if [ -n "${run_ledger:-}" ]; then
          fleet_alert_raise "$run_ledger" "$1" "$2" record-write \
            "record-write-$(printf '%s' "$fleet_run_flush_item" | tr './' '--')" \
            "applied/$2.yaml could not be updated for $fleet_run_flush_item" \
            "$fleet_run_flush_item" || :
        else
          fleet_alert_write "$1" "$2" record-write \
            "record-write-$(printf '%s' "$fleet_run_flush_item" | tr './' '--')" \
            "applied/$2.yaml could not be updated for $fleet_run_flush_item" \
            "$fleet_run_flush_item" || :
        fi
      done <"$fleet_run_batch/applied"
    fi
    : >"$fleet_run_batch/applied"
  fi
  [ "${3:-}" != applied-only ] || return 0
  if [ -s "$fleet_run_batch/journal" ]; then
    # One file per day of `at` (fleet_journal_path), in queue order.
    jq -c -R --arg us "$fleet_run_sep" 'split($us) |
      {item: .[0], digest: .[1], outcome: .[2], at: .[3]}' \
      <"$fleet_run_batch/journal" >"$fleet_run_batch/journal.json" 2>/dev/null || :
    # fleet_journal_entry_ok's verdict depends on an entry's keys, types and
    # outcome, never on its string contents, and every queued entry has the
    # same keys and string types — so one entry per outcome stands for all.
    jq -r '.outcome' <"$fleet_run_batch/journal.json" | LC_ALL=C sort -u |
      while IFS= read -r fleet_run_flush_outcome; do
        fleet_journal_entry_ok "$(jq -c --arg o "$fleet_run_flush_outcome" \
          'select(.outcome == $o)' <"$fleet_run_batch/journal.json" | head -1)" ||
          printf '%s\n' "$fleet_run_flush_outcome"
      done >"$fleet_run_batch/journal.refused"
    [ ! -s "$fleet_run_batch/journal.refused" ] ||
      printf 'roundhouse: refusing a journal entry that is not evidence-shaped\n' >&2
    jq -r 'select(.at != "") | .at | split("T")[0]' <"$fleet_run_batch/journal.json" |
      LC_ALL=C sort -u | while IFS= read -r fleet_run_flush_day; do
        fleet_run_flush_file=$(fleet_journal_path "$1" "$2" "$fleet_run_flush_day")
        fleet_record_write "$fleet_run_flush_file" \
          "$(fleet_record_read "$fleet_run_flush_file" '[]' |
            jq -c --slurpfile new "$fleet_run_batch/journal.json" \
              --rawfile refused "$fleet_run_batch/journal.refused" \
              --arg day "$fleet_run_flush_day" '
              ($refused | split("\n")) as $refused |
              . + [$new[] | select(.at != "" and (.at | split("T")[0]) == $day and
                ((.outcome) as $o | $refused | index($o) | not))]')" || :
      done
    : >"$fleet_run_batch/journal"
  fi
}
# --- §6.1 the two cadences, and the jitter that keeps them from synchronising -

fleet_run_jitter() {
  # fleet_run_jitter SEED SPAN -> a stable offset in [0, SPAN). Seeded from the
  # host NAME, never from the clock or a random draw: a fleet whose hosts
  # re-roll their offset every run converges on the same minute as often as it
  # spreads out, and jitter is this design's only coordination primitive
  # (§10.5 — there are no leases to fall back on).
  [ "${2:-0}" -gt 0 ] 2>/dev/null || {
    printf '0\n'
    return
  }
  fleet_run_seed=$(printf '%s' "$1" | sha256_stream | cut -c1-8)
  printf '%s\n' "$((0x$fleet_run_seed % $2))"
}

fleet_run_interval_seconds() {
  # fleet_run_interval_seconds FOLD HOST fast|full -> seconds until the next
  # run of that cadence, jittered symmetrically about the configured base.
  #
  # Policy comes from the FOLD — desired state like everything else, which is
  # what makes it reviewable, signed and fleet-wide (§5). Never from a file on
  # the box being governed: zeroing a knob locally must not weaken a gate.
  # `fleet_policy_int` FLOORS the value and falls back to the built-in default
  # on a non-number: a signed `cadence_hours: 12.0` (a realistic
  # digest-perturbing edit) reached bare `$(( ))` and crashed bash with an
  # undocumented exit, no alert, on every host at the next scheduling read.
  case $3 in
    fast)
      fleet_run_base=$(fleet_policy_int "$1" fast_interval_minutes)
      fleet_run_span=$(fleet_policy_int "$1" fast_jitter_minutes)
      ;;
    *)
      fleet_run_base=$(($(fleet_policy_int "$1" cadence_hours) * 60))
      fleet_run_span=$(fleet_policy_int "$1" jitter_minutes)
      ;;
  esac
  fleet_run_offset=$(fleet_run_jitter "$2" $((fleet_run_span * 2 + 1)))
  printf '%s\n' $(((fleet_run_base - fleet_run_span + fleet_run_offset) * 60))
}

fleet_run_stale_after() {
  # fleet_run_stale_after STORE HOST -> the run-lock staleness threshold, in
  # seconds: TWO FULL CADENCES, and never anything derived from the fast
  # interval.
  #
  # §10.6 is explicit about this and the reason is arithmetic: §6.1 introduced
  # a second, much shorter cadence, and `fast_interval_minutes` (20) through
  # the same expression gives a ~40-minute threshold — long enough to look
  # plausible and short enough to declare a LIVE full run's lock stale on the
  # very next fast run, which is how every later run gets stuck.
  #
  # The fold is read from the working copy rather than from the reviewed ref:
  # the lock is taken before anything resolves R, and a threshold that needed R
  # could not be computed at the moment it is needed. Absent policy falls
  # through to fleet_policy_defaults' 12 hours like every other reader.
  stale_fold=$(fleet_fold "$1" "$2" 2>/dev/null) || stale_fold=
  [ -n "$stale_fold" ] || stale_fold='{}'
  printf '%s\n' "$(($(fleet_policy_int "$stale_fold" cadence_hours) * 7200))"
}

# --- §6.1(a)/§6.4 the poll floor ---------------------------------------------

fleet_run_poll_floor() {
  # Exit 0 when there is genuinely nothing to do, with the reason in
  # $fleet_run_floor_note for the caller to print.
  #
  # §6.4: the remote check is about DESIRED STATE, not about the head. The
  # floor used to compare main@origin with `git ls-remote`, so every peer's
  # records commit — a journal line, an alert, an applied/ update, which every
  # pass of every host produced — forced a full pass on every other host. The
  # floor now fetches the remote head into a private ref (fleet_vcs_floor_fetch,
  # which moves no jj-visible ref) and compares the desired-state trees there
  # with those of the reference this host last CONVERGED FROM. Records-only
  # commits leave those trees byte-identical, so they no longer defeat the
  # floor; any change to a layer, definitions or trust/ does.
  #
  # The base is the converged REFERENCE (store.run/converged-desired), not the
  # published head: a full pass's maintenance half (re-seed, joins, trust
  # prune) edits layers AFTER it applied, and comparing against the head
  # would read those unapplied edits as already converged.
  fleet_run_floor_note=
  # The local conditions first — they are free, and any one of them is work.
  #
  # Nothing to push, and a clean working copy: a host with a committed-but-
  # unpushed edit and an unchanged remote must not exit and leave its own edit
  # unpublished. `present()` so a never-fetched store answers empty.
  fleet_run_pending=$(jj -R "$1" log \
    -r 'present(main@origin)..heads(bookmarks(exact:"main"))' \
    --no-graph -T 'commit_id ++ "\n"')
  [ -z "$fleet_run_pending" ] || return 1
  fleet_run_dirty=$(jj -R "$1" log -r @ --no-graph -T 'if(empty,"","x")')
  [ -z "$fleet_run_dirty" ] || return 1
  # Converged at this point: what makes this a PROPAGATION check rather than a
  # convergence one. A host that just cloned has nothing to pull and nothing
  # to push and has applied nothing, so without the marker it would sit idle.
  fleet_run_converged=$(cat "$(fleet_run_state_dir)/converged" 2>/dev/null) ||
    return 1
  [ -n "$fleet_run_converged" ] &&
    [ "$fleet_run_converged" = "$(fleet_vcs_heads_local "$1")" ] || return 1
  [ -s "$(fleet_run_state_dir)/converged-desired" ] || return 1
  # No published heartbeat owed (§6.3): only a pass that reaches the end
  # publishes one, so a floor that exited while one was due would make a quiet
  # host read as dead to every peer.
  ! fleet_heartbeat_due || return 1
  # No item waiting on canary evidence — that evidence arrives as RECORDS,
  # exactly what this floor ignores — and no retry owed: an apply that failed
  # or a gate whose input was transiently unavailable must be re-attempted,
  # and a host-local `fleet-review` verdict must be acted on, though nothing
  # on the remote moved.
  [ ! -e "$(fleet_run_state_dir)/canary-waiting" ] || return 1
  [ ! -e "$(fleet_run_state_dir)/retry-owed" ] || return 1

  fleet_run_fetched=$(fleet_vcs_floor_fetch "$1") || return 1
  [ -n "$fleet_run_fetched" ] || return 1
  # A fetched head that does not descend from what this host converged on is
  # a re-root or a rollback: that is the full pass's archive check to make
  # (§7.11.2), never something to sit out at the floor.
  git -C "$1" merge-base --is-ancestor "$fleet_run_converged" \
    "$fleet_run_fetched" 2>/dev/null || return 1
  [ "$(fleet_vcs_desired_digest "$1" "$fleet_run_fetched" 2>/dev/null)" = \
    "$(cat "$(fleet_run_state_dir)/converged-desired")" ] || return 1
  # No stale-host scan owed (§6.3): only a pass that reaches the end runs it
  # (fleet_liveness_owed says what owes one).
  ! fleet_liveness_owed "$1" "$fleet_run_fetched" || return 1
  # Last, because it is the one network question per marketplace: an
  # upstream plugin marketplace that moved is work the store cannot show
  # (fleet_plugins_probe, read-only `git ls-remote`).
  ! fleet_plugins_probe || return 1
  if [ "$fleet_run_fetched" = "$fleet_run_converged" ]; then
    fleet_run_floor_note='nothing new on the remote'
  else
    fleet_run_floor_note="$(git -C "$1" rev-list --count \
      "$fleet_run_converged..$fleet_run_fetched" 2>/dev/null || printf 'some') record-only commit(s) on the remote; the layers, definitions and trust/ are unchanged"
  fi
}

fleet_run_prune_empty() {
  # §8.1's invariant, repaired rather than asserted: @ must be a child of a
  # main target, and after `fleet-enroll` it is not.
  #
  # MEASURED on jj 0.44: `fleet-init` leaves an empty undescribed @, then
  # `fleet-enroll` runs `jj new -m ''` on top of it to get a post-enrollment
  # author — and jj does NOT abandon the first one, because a working-copy
  # commit is only abandoned when nothing is left standing on it. So the first
  # real convergence merges an EMPTY UNDESCRIBED COMMIT into main's ancestry
  # and every push from then on dies with "Won't push commit … since it has no
  # description". The store is bricked by its own bootstrap.
  #
  # Abandoning is lossless by construction — these commits are empty — and it
  # is the same operation jj performs itself in the case it does handle.
  jj -R "$1" log \
    -r '::@ ~ @ ~ ::(heads(bookmarks(exact:"main")) | present(main@origin))' \
    --no-graph -T 'commit_id ++ "\n"' 2>/dev/null |
    while IFS= read -r fleet_run_stale; do
      [ -n "$fleet_run_stale" ] || continue
      [ "$(jj -R "$1" log -r "$fleet_run_stale" --no-graph \
        -T 'if(empty, if(description, "n", "y"), "n")')" = y ] || continue
      jj -R "$1" abandon -r "$fleet_run_stale" >/dev/null 2>&1 || :
    done
}

# --- reviewed content: the layers at a real commit ----------------------------

fleet_run_layer_path() {
  # Store-relative paths the fold reads. Everything else in the tree is a
  # record: evidence a host publishes about itself, never desired state.
  #
  # A case glob's `*` matches `/`, so `hosts/*.yaml` already covers §2's
  # directory form (`hosts/wren/skills.yaml`) — spelling both is a pattern that
  # can never match.
  case $1 in
    fleet.yaml | definitions.yaml | fleet/*.yaml | os/*.yaml | groups/*.yaml | \
      hosts/*.yaml) ;;
    definitions/*.yaml) fleet_definitions_file_path "$1" || return 1 ;;
    *) return 1 ;;
  esac
}

fleet_run_export() {
  # fleet_run_export STORE REV DEST — the layers at REV as plain files, so the
  # fold runs over a real commit without a checkout and without touching the
  # working copy. This is how §8.3 reads each head while the merge is
  # conflicted: `jj file show -r <head>` returns clean per-side YAML that yq
  # parses, and the conflicted commit's own content does not.
  #
  # `-T 'path'` is not decoration: a bare `jj file list` prints paths relative
  # to the CALLER's working directory, so from anywhere else every line comes
  # back as `../../../store/hosts/vireo.yaml`. Measured on jj 0.44.
  #
  # `--ignore-working-copy` on every read: REV names a commit, so snapshotting
  # @ first answers nothing about it, and on a store carrying tens of
  # thousands of evidence files each snapshot cost ~150 ms per call.
  mkdir -p "$3"
  # The cheap prefix filter only narrows what fleet_run_layer_path, the one
  # predicate, is asked about: tens of thousands of evidence paths never reach
  # a shell function call.
  fleet_run_export_paths=$(jj --ignore-working-copy -R "$1" file list -r "$2" \
    -T 'path ++ "\n"' 2>/dev/null |
    grep -E '^(fleet\.yaml|definitions\.yaml|(fleet|os|groups|hosts|definitions)/)' |
    while IFS= read -r fleet_run_path; do
      ! fleet_run_layer_path "$fleet_run_path" || printf '%s\n' "$fleet_run_path"
    done)
  [ -n "$fleet_run_export_paths" ] || return 0
  {
    printf '%s\0' "$3"
    printf '%s\n' "$fleet_run_export_paths" | while IFS= read -r fleet_run_path; do
      case $fleet_run_path in
        */*) printf '%s\0' "$3/${fleet_run_path%/*}" ;;
      esac
    done
  } | xargs -0 mkdir -p
  fleet_run_export_batch "$1" "$2" "$3" "$fleet_run_export_paths" && return 0
  printf '%s\n' "$fleet_run_export_paths" | while IFS= read -r fleet_run_path; do
    # `root:` makes the argument repo-root-relative regardless of cwd.
    jj --ignore-working-copy -R "$1" file show -r "$2" "root:$fleet_run_path" \
      >"$3/$fleet_run_path" 2>/dev/null || :
  done
}

fleet_run_export_batch() {
  # fleet_run_export_batch STORE REV DEST PATHS — every layer file in ONE
  # `jj file show`, split back into files byte-for-byte; non-zero (and the
  # caller falls back to one call per file) on anything it cannot prove.
  #
  # Each file is preceded by a marker line carrying a per-call random nonce,
  # and the marker is itself preceded by a newline this function adds. So the
  # bytes before a marker are the previous file plus exactly ONE added `\n`,
  # whether or not that file ended in a newline, and dropping that one byte
  # restores the file exactly — which matters, because a block scalar at the
  # end of a file without a final newline parses differently with one.
  fleet_run_export_tmp=$(mktemp "${TMPDIR:-/tmp}/roundhouse-export.XXXXXX") || return 1
  fleet_run_export_nonce=$(od -An -N12 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
  [ -n "$fleet_run_export_nonce" ] || {
    rm -f "$fleet_run_export_tmp"
    return 1
  }
  # One `root:` fileset per layer path, as the per-file form passes it.
  while IFS= read -r fleet_run_export_path; do
    set -- "$@" "root:$fleet_run_export_path"
  done <<EOF
$4
EOF
  {
    jj --ignore-working-copy -R "$1" file show -r "$2" \
      -T "\"\\n==RH-$fleet_run_export_nonce \" ++ path ++ \"\\n\"" \
      "${@:5}" 2>/dev/null &&
      printf '\n==RH-%s \n' "$fleet_run_export_nonce"
  } >"$fleet_run_export_tmp" || {
    rm -f "$fleet_run_export_tmp"
    return 1
  }
  # A NUL would not survive awk, and no YAML file carries one.
  [ "$(LC_ALL=C tr -d '\000' <"$fleet_run_export_tmp" | wc -c)" = \
    "$(wc -c <"$fleet_run_export_tmp")" ] || {
    rm -f "$fleet_run_export_tmp"
    return 1
  }
  fleet_run_export_status=0
  printf '%s\n' "$4" | LC_ALL=C awk -v marker="==RH-$fleet_run_export_nonce " \
    -v dest="$3" '
    function flush(   f, i) {
      if (cur == "") return
      f = dest "/" cur
      printf "" > f
      for (i = 1; i <= n; i++) printf "%s%s", line[i], (i < n ? "\n" : "") > f
      close(f)
      cur = ""
    }
    NR == FNR { want[$0] = 1; next }
    index($0, marker) == 1 {
      flush()
      p = substr($0, length(marker) + 1)
      if (p == "") { done = 1; next }
      if (done || !(p in want) || (p in seen)) { bad = 1; next }
      seen[p] = 1; cur = p; n = 0
      next
    }
    cur != "" { line[++n] = $0 }
    END {
      flush()
      for (p in want) if (!(p in seen)) bad = 1
      exit (bad || !done) ? 1 : 0
    }
  ' - "$fleet_run_export_tmp" || fleet_run_export_status=1
  rm -f "$fleet_run_export_tmp"
  return "$fleet_run_export_status"
}

fleet_run_item_digests() {
  # fleet_run_item_digests FOLD [LAYERDIR] -> `<item> <digest>` lines, which is
  # exactly what §8.3's hold set reads.
  #
  # LAYERDIR brings the definitions file/directory INTO THE ITEM UNIVERSE. It is correctly
  # outside the fold (§5.1 — a mapping is a lookup, not a want), and nothing
  # else enumerated it either, so `definitions.*` had no digest, no verdict, no
  # §8.3 hold entry and no §7.7 narrow-hold entry. That made rule 6's
  # deliberately-narrow hold set EMPTY for a definitions-only commit: an
  # `ephemeral` leaf — 40/day by construction — could commit nothing but
  # definitions content, be correctly refused by the class rule, produce zero
  # holds, and have the run clone its skill source and install its package
  # anyway. §5.1's "the `definitions.` prefix is load-bearing" is what keeps
  # `definitions.packages.jj` and `packages.jj` from sharing one verdict key.
  #
  # One batch over the whole item set (lib/fleet-fold.sh): the same values and
  # the same digests the per-item fleet_item_digest loop printed, in the same
  # order, without four processes per item.
  {
    fleet_fold_item_values "$1"
    [ -z "${2:-}" ] || fleet_definition_item_values "$(fleet_definitions_load "$2")"
  } | fleet_value_digests
}

fleet_run_item_layer() {
  # fleet_run_item_layer LAYERDIR HOST ITEM -> the store-relative layer file
  # whose opinion wins. Provenance is FILE, never file:line: yq's `line`
  # operator does not count comment-only lines, and every layer file is
  # commented by design, so a confidently wrong number is worse than none.
  fleet_run_split=$(fleet_item_split "$3") || return 1
  fleet_run_category=$(printf '%s\n' "$fleet_run_split" | sed -n 1p)
  fleet_run_name=$(printf '%s\n' "$fleet_run_split" | sed -n 2p)
  fleet_run_winner=
  while IFS= read -r fleet_run_file; do
    [ -n "$fleet_run_file" ] || continue
    [ "$(fleet_explain_layer_value "$fleet_run_file" "$fleet_run_category" \
      "$fleet_run_name")" = '""' ] || fleet_run_winner=$fleet_run_file
  done <<EOF
$(fleet_layer_files "$1" "$2")
EOF
  [ -n "$fleet_run_winner" ] || return 1
  printf '%s\n' "${fleet_run_winner#"$1/"}"
}

# --- §6 step 4: the promote gate, and §8.2's precedence over it ---------------

fleet_run_promote_gate() {
  # Every changed layer file in @ must parse. If they do, the run describes @
  # and moves the bookmark to it (which is what the §8.2 runbook's steps 1-2
  # do). If they don't, it REFUSES to promote and converges from the last good
  # `main` — a broken file never becomes the reviewed line.
  #
  # Prints `<file>: <yq's own message>` per failure; silence is clean.
  #
  # THE §8.2 PRECEDENCE IS THE CALLER'S, and it is skipped here for the one
  # state that would otherwise fire it spuriously: a layer file carrying
  # snapshot markers fails `yq -e '.'`, so on the conflicted path this gate
  # would alert every run pointing at a line number INSIDE a conflict marker,
  # and pick a different reconcile point than §8.2/§8.3. One state, one
  # answer: §8.2 wins.
  [ -z "$(fleet_vcs_conflicted "$1" @)" ] || return 0
  fleet_run_broken=0
  while IFS= read -r fleet_run_changed; do
    [ -n "$fleet_run_changed" ] || continue
    fleet_run_layer_path "$fleet_run_changed" || continue
    [ -f "$1/$fleet_run_changed" ] || continue
    fleet_run_parse=$(yq -e '.' "$1/$fleet_run_changed" 2>&1 >/dev/null) || {
      printf '%s: %s\n' "$fleet_run_changed" \
        "$(printf '%s' "$fleet_run_parse" | tr '\n' ' ')"
      fleet_run_broken=1
    }
  done <<EOF
$(cd "$1" && jj diff -r @ --name-only 2>/dev/null)
EOF
  # `jj diff --name-only` refuses -T, so it runs with cwd INSIDE the store or
  # every name comes back absolute.
  [ "$fleet_run_broken" -eq 0 ]
}

# --- §7.1/§7.3/§7.7: hold only what an unverifiable commit touched ------------

fleet_run_file_items() {
  # fleet_run_file_items <file-on-disk> [store-relative-path] — every item a
  # layer file contributes, `<category>.<name>`.
  #
  # A definitions file contributes DEFINITIONS items, under the reserved prefix.
  # Without it this function emitted `packages.jj` for the definitions file, so
  # a file-scoped refusal of a definitions edit held the coincidentally
  # same-named DESIRED items and never the mapping — §5.1's "the `definitions.`
  # prefix is load-bearing, not decoration", read backwards.
  # yq does the YAML->JSON step and jq does the rest, because yq's `as` binding
  # EVALUATES ITS BODY ONCE ON AN EMPTY STREAM: measured on yq v4.53,
  # `to_entries[] | select(…) | .key as $c | … "\($c).\(.)"` over a file with no
  # map-valued top-level key (every host facts file: `platform: macos`) emits a
  # bare `.` — a bogus item id that entered every file-scoped hold set. jq's
  # empty stream stays empty.
  #
  # The parse status is captured rather than piped: jq exits 0 on empty stdin,
  # so an unparsable file would otherwise read as "this file contributes no
  # items" and hold nothing.
  fleet_run_file_path=${2:-$1}
  case $fleet_run_file_path in
    definitions.yaml | definitions/*.yaml)
      case $fleet_run_file_path in
        definitions/*.yaml)
          fleet_definitions_file_path "$fleet_run_file_path" || return 1
          ;;
      esac
      fleet_run_ns=definitions. ;;
    *) fleet_run_ns= ;;
  esac
  fleet_run_fi_json=$(yq -o=json -I=0 '. // {}' "$1" 2>/dev/null) || return 1
  [ -n "$fleet_run_fi_json" ] || return 1
  printf '%s\n' "$fleet_run_fi_json" |
    jq -r --arg ns "$fleet_run_ns" '
      to_entries[] | select(.value | type == "object") |
      .key as $c | .value | keys[] | "\($ns)\($c).\(.)"'
}

fleet_run_file_items_at_change() {
  # fleet_run_file_items_at_change STORE COMMIT LAYERDIR PATH WORKDIR — the
  # union of the items this changed path contributes before and after the
  # commit. A deleted file (or a deleted key inside a surviving file) has no
  # post-change file to inspect, so using only the reviewed export silently
  # drops the item that must be held.
  fleet_run_file_item_list=$5/file-items
  fleet_run_file_parent_dir=$5/file-parent
  rm -rf "$fleet_run_file_parent_dir"
  : >"$fleet_run_file_item_list"
  if [ -f "$3/$4" ]; then
    fleet_run_file_items "$3/$4" "$4" >>"$fleet_run_file_item_list" || :
  fi
  for fleet_run_file_parent in $(fleet_trust_parents "$1" "$2"); do
    rm -rf "$fleet_run_file_parent_dir"
    fleet_run_export "$1" "$fleet_run_file_parent" \
      "$fleet_run_file_parent_dir" 2>/dev/null || continue
    [ -f "$fleet_run_file_parent_dir/$4" ] || continue
    fleet_run_file_items "$fleet_run_file_parent_dir/$4" "$4" \
      >>"$fleet_run_file_item_list" || :
  done
  LC_ALL=C sort -u "$fleet_run_file_item_list"
}

fleet_run_changed_items() {
  # fleet_run_changed_items STORE COMMIT HOST WORKDIR -> the items whose
  # VALUE this commit actually changed, by §8.3's per-parent comparison reused
  # verbatim: fold the layers at each real parent and at the commit, and take
  # the items whose digest differs (an item that appears or disappears differs
  # like any other).
  #
  # This is the narrower hold set §7.7 gives a CLASS refusal specifically —
  # where the content parses and the signature is good and only the author's
  # authority is wrong. Verified on a leaf touching one key of a three-key
  # layer file: file-scoped hold = a,b,c; item-scoped hold = b. A leaf can still
  # degrade what it touched; it can no longer freeze a file by brushing
  # against it.
  rm -rf "$4/at" "$4/before"
  fleet_run_export "$1" "$2" "$4/at" 2>/dev/null || return 0
  fleet_run_item_digests "$(fleet_fold "$4/at" "$3" 2>/dev/null || printf '{}')" \
    "$4/at" >"$4/digests.at"
  : >"$4/digests.before"
  for fleet_run_cparent in $(fleet_trust_parents "$1" "$2"); do
    rm -rf "$4/before"
    fleet_run_export "$1" "$fleet_run_cparent" "$4/before" 2>/dev/null || continue
    fleet_run_item_digests \
      "$(fleet_fold "$4/before" "$3" 2>/dev/null || printf '{}')" "$4/before" \
      >>"$4/digests.before"
  done
  LC_ALL=C sort -u "$4/digests.before" >"$4/digests.before.u"
  LC_ALL=C sort -u "$4/digests.at" >"$4/digests.at.u"
  # BOTH directions. An item this commit REMOVED changed just as much as one it
  # rewrote, and taking only the additions would let a refused author delete an
  # item from a shared layer without that item being held.
  comm -3 "$4/digests.at.u" "$4/digests.before.u" | awk '{ print $1 }' |
    LC_ALL=C sort -u
}

fleet_run_signature_holds() {
  # fleet_run_signature_holds STORE RANGE HOSTS_FILE LAYERDIR HOST
  #   [REVIEWED-ROSTER] [WORKDIR]
  #
  # §7.7's unifying rule: a bad edit NARROWS what is applicable; it never
  # breaks the store and never blocks unrelated items. Every failure is
  # item-scoped, and a class refusal is scoped narrower still.
  #
  # THE RATCHET LOOP. Each commit is verified against the roster materialized
  # from EVERY ONE OF ITS PARENTS — never `jj file show -r <C>-`, which for a
  # merge silently picks one and lets a removed member keep pushing forever by
  # parenting its commits before its own removal (§7.1). §8.2 manufactures
  # merges as its normal path, so the singular reading is not a corner case.
  #
  # Prints `<item> <reason>` lines, plus the reserved marker `!hold <reason>`
  # for a condition whose scope is the WHOLE run. `!hold` can never collide
  # with an item id, which is always `<category>.<name>` and always carries a
  # dot; the caller escalates it to a fleet alert and `exit 65`.
  #
  # A MISSING KRL IS NOT "NO HOLDS". `fleet_trust_krl >/dev/null 2>&1 ||
  # return 0` discarded the warning and returned the same empty output a fully
  # verified range produces, so deleting one user-writable file turned every
  # gate in §7 off silently — unsigned commits, foreign principals and retired
  # members all applied, and §7.1a says the opposite ("returns `bad` for
  # everything … refused loudly"). The bootstrap carve-out survives, narrowed
  # to the state that actually needs it: a store between fleet-init and
  # fleet-enroll, which has no genesis yet and so has nothing to verify against.
  fleet_run_krlerr=$(fleet_trust_krl 2>&1 >/dev/null) || {
    [ -n "$(fleet_store_id "$1")" ] || return 0
    printf '!hold %s\n' \
      "${fleet_run_krlerr:-no usable revocation list}; every signature would report bad, so nothing can be verified (§7.1a)"
    return 0
  }
  fleet_run_sigwork=${7:-$(fleet_run_state_dir)}
  mkdir -p "$fleet_run_sigwork"
  # The roster AS THE GENESIS COMMIT STATED IT, rendered once: it is what tells
  # a real `channel_auth: genesis` from one an attacker typed into their own
  # block later. Absent (a store with no genesis yet) means no principal is a
  # genesis member, which is the safe direction.
  fleet_run_store_genesis=$(fleet_store_id "$1")
  fleet_run_genesis_roster=
  [ -z "$fleet_run_store_genesis" ] || {
    fleet_run_genesis_roster=$fleet_run_sigwork/genesis-roster
    fleet_trust_roster_at_head "$1" "$fleet_run_store_genesis" \
      "$fleet_run_genesis_roster"
  }
  # The commits, once, in walk order — and the timestamps the ratchet reads
  # for each of them and their parents, prefetched in one call.
  fleet_run_sigcommits=$(jj --ignore-working-copy -R "$1" log -r "$2" --no-graph \
    -T 'commit_id ++ "\n"' 2>/dev/null) || fleet_run_sigcommits=
  fleet_trust_memo=$fleet_run_sigwork/trust-memo
  rm -rf "$fleet_trust_memo"
  fleet_trust_memo_times "$1" "$2"
  # CLEAN COMMITS ARE REMEMBERED, host-locally, and only clean ones. A commit
  # whose every check passed — it verifies, and every path it touches passed
  # the identity, class and soak rules — prints nothing, and every input that
  # decides that is either part of the commit (its content, its parents'
  # rosters, its time) or named in the key: the revocation list, the reviewed
  # roster rule 4 reads, the enrolled-host table, the genesis roster, the
  # genesis pin and this code. Any key change reads as an empty memo and the
  # whole range is walked again; a commit that printed anything, or failed any
  # check at all, is never remembered and is always re-walked.
  fleet_run_sigclean_key=$(fleet_run_sigholds_key "$1" "${6:-}" "$3" \
    "$fleet_run_genesis_roster") || fleet_run_sigclean_key=
  fleet_run_sigclean_file=$(fleet_run_state_dir)/sigholds-clean
  fleet_run_sigclean_old=
  [ -z "$fleet_run_sigclean_key" ] ||
    fleet_run_sigclean_old=$(fleet_run_memo_read "$fleet_run_sigclean_file" \
      "$fleet_run_sigclean_key") || fleet_run_sigclean_old=
  : >"$fleet_run_sigwork/sigholds-clean.new"
  while IFS= read -r fleet_run_commit; do
    [ -n "$fleet_run_commit" ] || continue
    case "
$fleet_run_sigclean_old
" in
      *"
$fleet_run_commit
"*)
        printf '%s\n' "$fleet_run_commit" >>"$fleet_run_sigwork/sigholds-clean.new"
        continue
        ;;
    esac
    fleet_run_roster="$fleet_run_sigwork/roster.$fleet_run_commit"
    fleet_run_signature_commit "$1" "$fleet_run_commit" "$3" "$4" "$5" "${6:-}" \
      "$fleet_run_roster" "$fleet_run_genesis_roster" >"$fleet_run_sigwork/commit.out"
    cat "$fleet_run_sigwork/commit.out"
    [ ! -f "$fleet_run_roster/clean" ] || [ -s "$fleet_run_sigwork/commit.out" ] ||
      printf '%s\n' "$fleet_run_commit" >>"$fleet_run_sigwork/sigholds-clean.new"
  done <<EOF
$fleet_run_sigcommits
EOF
  # Bounded by the range: only commits this walk saw are kept.
  [ -z "$fleet_run_sigclean_key" ] ||
    LC_ALL=C sort -u "$fleet_run_sigwork/sigholds-clean.new" |
    fleet_run_memo_write "$fleet_run_sigclean_file" "$fleet_run_sigclean_key"
  rm -rf "$fleet_trust_memo"
  fleet_trust_memo=
}

fleet_run_memo_read() {
  # fleet_run_memo_read FILE KEY -> the commit ids a host-local memo records,
  # or non-zero (and nothing) unless the memo is exactly what
  # fleet_run_memo_write wrote under KEY: the header names the key AND the
  # sha256 of the body, so a missing, truncated, corrupted or differently
  # keyed memo reads as EMPTY — everything is walked again. Fail closed.
  [ -f "$1" ] || return 1
  fleet_run_memo_header=$(sed -n 1p "$1" 2>/dev/null) || return 1
  case $fleet_run_memo_header in
    "v1 $2 "????????????????????????????????????????????????????????????????) ;;
    *) return 1 ;;
  esac
  [ "$(sed 1d "$1" | sha256_stream)" = "${fleet_run_memo_header##* }" ] || return 1
  sed 1d "$1" | grep -E '^[0-9a-f]{40}$' || :
}

fleet_run_memo_write() {
  # fleet_run_memo_write FILE KEY < commit ids — atomically, with the header
  # fleet_run_memo_read checks. A memo that cannot be written is simply absent.
  mkdir -p "$(dirname "$1")" 2>/dev/null || :
  fleet_run_memo_tmp=$(mktemp "$1.XXXXXX" 2>/dev/null) || {
    cat >/dev/null
    return 0
  }
  cat >"$fleet_run_memo_tmp.body"
  { printf 'v1 %s %s\n' "$2" "$(sha256_stream <"$fleet_run_memo_tmp.body")"
    cat "$fleet_run_memo_tmp.body"; } >"$fleet_run_memo_tmp" &&
    mv -f "$fleet_run_memo_tmp" "$1" || rm -f "$fleet_run_memo_tmp"
  rm -f "$fleet_run_memo_tmp.body"
}

fleet_run_sigholds_key() {
  # fleet_run_sigholds_key STORE REVIEWED-ROSTER HOSTS GENESIS-ROSTER -> the
  # digest of every input outside a commit that decides whether it walks
  # clean, or non-zero (no memo this run) when one cannot be read.
  fleet_run_key_krl=$(fleet_trust_krl 2>/dev/null) || return 1
  fleet_run_key_tmp=$(mktemp "${TMPDIR:-/tmp}/roundhouse-sigkey.XXXXXX") || return 1
  fleet_run_key_ok=true
  {
    printf 'krl\n'
    cat "$fleet_run_key_krl" || fleet_run_key_ok=false
    printf '\nreviewed\n'
    [ -z "$2" ] || [ ! -f "$2" ] || cat "$2" || fleet_run_key_ok=false
    printf '\nhosts\n'
    cat "$3" || fleet_run_key_ok=false
    printf '\ngenesis\n'
    [ -z "$4" ] || [ ! -f "$4" ] || cat "$4" || fleet_run_key_ok=false
    printf '\npin %s\n' "$(fleet_identity_get store_id)"
    # The code identity is ALL of it, not a list of the files believed to
    # matter today: a rule tightened anywhere (an ownership table in
    # fleet-fold.sh, say) must re-walk every commit remembered as clean.
    printf '\ncode\n'
    cat "$script_dir/roundhouse" "$script_dir"/lib/*.sh || fleet_run_key_ok=false
  } >"$fleet_run_key_tmp" 2>/dev/null
  if [ "$fleet_run_key_ok" = true ]; then
    sha256_stream <"$fleet_run_key_tmp"
  fi
  rm -f "$fleet_run_key_tmp"
  [ "$fleet_run_key_ok" = true ]
}

fleet_run_owner_memo_key() {
  # fleet_run_owner_memo_key OWNER — sets fleet_run_memo_owner to OWNER when
  # it is safe to key the walk's `|owner=answer|` memos on it (the three
  # special owners, or a name in a charset with no separator or glob
  # character), and to empty otherwise. A global, not output: it is asked
  # once per touched path.
  fleet_run_memo_owner=$1
  case $1 in
    '*' | '+' | '?') ;;
    '' | *[!A-Za-z0-9._@-]*) fleet_run_memo_owner= ;;
  esac
}

fleet_run_signature_commit() {
  # fleet_run_signature_commit STORE COMMIT HOSTS LAYERDIR HOST REVIEWED-ROSTER
  #   WORKDIR GENESIS-ROSTER — one commit of fleet_run_signature_holds' walk,
  # printing its lines. Leaves WORKDIR/clean when the commit verified and every
  # path it touches passed every rule (the only commits the walk remembers).
  #
  # Each rule below is still asked of its own predicate. What changed is how
  # often: the soak, the commit time and the principal are properties of the
  # COMMIT, and the identity and class answers depend on a path only through
  # its owner (fleet_vcs_path_owner), so each is asked once per commit or once
  # per owner rather than once per touched path — a commit touching 500
  # proposals asked the same three questions 500 times.
  # Nothing a previous walk left in WORKDIR may answer for this one.
  rm -f "$7/clean" "$7/signature"
  fleet_run_reason=$(fleet_trust_commit_hold "$1" "$2" "$7" "$6") ||
    fleet_run_reason=${fleet_run_reason:-unverifiable}
  # `jj diff --name-only` refuses -T and prints paths relative to the CALLER's
  # directory, so it runs with cwd INSIDE the store or every name comes back
  # absolute. Read once; the walk below and the roster check read the same list.
  # A path list that could not be read is walked as before (empty), but the
  # commit is never remembered clean on it: the next run reads it again.
  fleet_run_touched_ok=true
  fleet_run_touched_all=$(cd "$1" && jj --ignore-working-copy diff -r "$2" \
    --name-only 2>/dev/null) || fleet_run_touched_ok=false
  # A REJECTED ROSTER COMMIT ESCALATES OUT OF THE ITEM-SCOPED PATH.
  # `trust/signers.yaml` is not a layer path, so a commit that fails
  # verification while rewriting the roster held NOTHING — every hold below
  # is scoped to layer files that exist in the exported tree — while still
  # supplying the roster its children are verified against. That is the
  # §7.12.5 bypass in two commits: C1 adds the attacker's own key and is
  # correctly refused; C2, its child, is then verified against C1's bytes,
  # comes back `good`, and writes desired state. The ratchet checks each
  # commit against whatever sits at its parent; nothing required the commit
  # that PUT those bytes there to have verified. Until derivation carries
  # only verified roster state forward, a failed roster commit is a
  # store-wide refusal.
  if [ -n "$fleet_run_reason" ] &&
    printf '%s\n' "$fleet_run_touched_all" | grep -Fqx "$fleet_trust_roster_file"; then
    printf '!hold %s\n' \
      "commit $2 rewrites $fleet_trust_roster_file and does not verify: $fleet_run_reason"
  fi
  # The principal the SIGNATURE derives — the very read commit_hold just made,
  # when it got that far; otherwise asked again, as it always was.
  if [ -f "$7/signature" ]; then
    fleet_run_principal=$(awk '{ print $2 }' "$7/signature")
  else
    fleet_run_principal=$(fleet_trust_principal "$1" "$2" "$7/roster")
  fi
  fleet_run_class=$(fleet_trust_class_of "$7/classes" "$fleet_run_principal")
  fleet_run_narrow=
  fleet_run_any_bad=$fleet_run_reason
  fleet_run_soak=
  # `|owner=answer|` memos for the two owner-shaped rules.
  fleet_run_identity_memo='|'
  fleet_run_class_memo='|'
  while IFS= read -r fleet_run_touched; do
    [ -n "$fleet_run_touched" ] || continue
    fleet_run_bad=$fleet_run_reason
    fleet_run_scope=file
    fleet_run_owner='?'
    ! fleet_vcs_path_owner "$fleet_run_touched" >/dev/null 2>&1 ||
      fleet_run_owner=$fleet_vcs_owner_of
    # Only an owner that cannot spell the memo's own separators is memoized:
    # the owner comes from the path, and a committed path such as
    # `alerts/*=1|y=1|w/…` would otherwise plant an answer for another owner.
    # Anything else is asked every time, as before.
    fleet_run_owner_memo_key "$fleet_run_owner"
    if [ -z "$fleet_run_bad" ]; then
      case ${fleet_run_memo_owner:+$fleet_run_identity_memo} in
        *"|$fleet_run_memo_owner=0|"*) fleet_run_identity=0 ;;
        *"|$fleet_run_memo_owner=1|"*) fleet_run_identity=1 ;;
        *)
          fleet_run_identity=1
          fleet_vcs_path_identity_ok "$fleet_run_touched" \
            "$fleet_run_principal" "$3" || fleet_run_identity=0
          [ -z "$fleet_run_memo_owner" ] ||
            fleet_run_identity_memo="$fleet_run_identity_memo$fleet_run_memo_owner=$fleet_run_identity|"
          ;;
      esac
      [ "$fleet_run_identity" = 1 ] ||
        fleet_run_bad="path $fleet_run_touched may not be authored by $fleet_run_principal"
    fi
    # Rule 6, and its hold set is DELIBERATELY narrower than every other
    # failure's: the content parses and the signature is good, so there is
    # no reason to distrust the untouched items.
    if [ -z "$fleet_run_bad" ]; then
      case ${fleet_run_memo_owner:+$fleet_run_class_memo} in
        *"|$fleet_run_memo_owner=0|"*) fleet_run_allowed=0 ;;
        *"|$fleet_run_memo_owner=1|"*) fleet_run_allowed=1 ;;
        *)
          fleet_run_allowed=1
          fleet_trust_class_allows "$fleet_run_class" "$fleet_run_touched" ||
            fleet_run_allowed=0
          [ -z "$fleet_run_memo_owner" ] ||
            fleet_run_class_memo="$fleet_run_class_memo$fleet_run_memo_owner=$fleet_run_allowed|"
          ;;
      esac
      if [ "$fleet_run_allowed" = 0 ]; then
        fleet_run_bad="class $fleet_run_class may not write $fleet_run_touched"
        fleet_run_scope=item
      fi
    fi
    # §7.12.1's soak, evaluated from the SAME derived roster the class
    # came from — reading it at the current head would let an attacker's
    # own later commit shorten their own soak.
    if [ -z "$fleet_run_bad" ] && [ "$fleet_run_owner" = '*' ]; then
      if [ -z "$fleet_run_soak" ]; then
        fleet_run_soak=closed
        if [ -f "$7/at" ]; then
          IFS= read -r fleet_run_commit_at <"$7/at" || fleet_run_commit_at=
        else
          fleet_run_commit_at=$(fleet_trust_commit_time "$1" "$2")
        fi
        ! fleet_trust_soak_open "$7/classes" "$fleet_run_principal" \
          "$fleet_run_commit_at" "$8" || fleet_run_soak=open
      fi
      [ "$fleet_run_soak" != open ] ||
        fleet_run_bad="$fleet_run_principal is inside its enrollment soak window and may not write fleet layers yet"
    fi
    [ -n "$fleet_run_bad" ] || continue
    fleet_run_any_bad=$fleet_run_bad
    # A FAILURE THAT TOUCHES A §7-VERIFICATION PATH ESCALATES TO A
    # STORE-WIDE HOLD, never a dropped item hold. trust/, checkpoints/,
    # lineage/ and proposals/ are not layer paths, so the item-scoped
    # `fleet_run_layer_path || continue` below discarded their computed
    # `fleet_run_bad` entirely — a leaf holding a real key with a good
    # signature could author a `trust/signers.yaml` edit adding a durable
    # key, be refused by the class rule, produce NO hold, and have it
    # materialized fleet-wide. This is the §7.12.5 boundary; treat it
    # exactly like the unverifiable-roster-commit escalation above.
    case $fleet_run_touched in
      trust/* | checkpoints/* | lineage/* | proposals/*)
        printf '!hold %s\n' \
          "commit $2 writes $fleet_run_touched and does not satisfy §7 verification: $fleet_run_bad"
        continue
        ;;
    esac
    fleet_run_layer_path "$fleet_run_touched" || continue
    fleet_run_changed_file_items=$(fleet_run_file_items_at_change \
      "$1" "$2" "$4" "$fleet_run_touched" "$7")
    [ -n "$fleet_run_changed_file_items" ] || continue
    if [ "$fleet_run_scope" = item ]; then
      [ -n "$fleet_run_narrow" ] || {
        fleet_run_changed_items "$1" "$2" "$5" "$7" >"$7/narrow"
        fleet_run_narrow=$7/narrow
      }
      printf '%s\n' "$fleet_run_changed_file_items" |
        comm -12 - "$fleet_run_narrow" |
        while IFS= read -r fleet_run_held_item; do
          [ -n "$fleet_run_held_item" ] || continue
          printf '%s %s\n' "$fleet_run_held_item" "$fleet_run_bad"
        done
      continue
    fi
    printf '%s\n' "$fleet_run_changed_file_items" |
      while IFS= read -r fleet_run_held_item; do
        [ -n "$fleet_run_held_item" ] || continue
        printf '%s %s\n' "$fleet_run_held_item" "$fleet_run_bad"
      done
  done <<EOF
$fleet_run_touched_all
EOF
  [ -n "$fleet_run_any_bad" ] || [ "$fleet_run_touched_ok" != true ] || : >"$7/clean"
}

# --- §8.2b: the evidence the ladder decides on --------------------------------

fleet_run_trailer() {
  # fleet_run_trailer STORE REV NAME — one §5 trailer off a commit
  # description. SELF-ASSERTED free text: exactly one rule in the ladder reads
  # it (rule 2), and that rule's only possible outcome is escalation.
  jj -R "$1" log -r "$2" --no-graph -T 'description' 2>/dev/null |
    sed -n "s/^$3: //p" | tail -1
}

fleet_run_side_session() {
  # fleet_run_side_session STORE SIDE OTHER — §8.2b rule 2's input, read over
  # the side's UNIQUE RANGE and not at its tip.
  #
  # RULE 2 COULD NOT FIRE ON A REAL HAND EDIT. Roundhouse stamps every head it
  # publishes `scheduled/agent` (fleet_run_publish, fleet_vcs_reconcile), and
  # §8.2 step 1 folds the operator's edit in as a PARENT of the merge — so the
  # operator's `interactive/human` trailer is never on a head, and reading one
  # commit found `scheduled/agent` on both sides every time. The ladder then
  # arbitrated with rule 4 or 5 and the hand edit SILENTLY LOST, with a
  # `resolved` journal record asserting it was decided on grounded evidence.
  # §8.2b pays for the opposite explicitly: "a genuine hand edit conflicting
  # with an agent edit escalates instead of silently winning."
  #
  # The question the rule asks is "is a human on this side", which is a question
  # about the range, not about one commit. `fleet_resolve_is_human` is already
  # the right predicate — only the input revset was wrong — and it fails an
  # unrecognised or absent session kind TOWARD the human, which is why a
  # trailerless commit anywhere in the range escalates.
  fleet_run_sess_range=$2
  [ -z "${3:-}" ] || fleet_run_sess_range="$3..$2"
  fleet_run_sess_found=
  while IFS= read -r fleet_run_sess_commit; do
    [ -n "$fleet_run_sess_commit" ] || continue
    ! fleet_resolve_is_human \
      "$(fleet_run_trailer "$1" "$fleet_run_sess_commit" roundhouse-session)" ||
      fleet_run_sess_found=interactive/human
  done <<EOF
$(jj -R "$1" log -r "$fleet_run_sess_range" --no-graph -T 'commit_id ++ "\n"' \
  2>/dev/null)
EOF
  printf '%s\n' \
    "${fleet_run_sess_found:-$(fleet_run_trailer "$1" "$2" roundhouse-session)}"
}

fleet_run_applied_elsewhere() {
  # fleet_run_applied_elsewhere STORE SELF ITEM DIGEST HOSTS_FILE
  #
  # §8.2b's replicated-journal class, read off `applied/<h>.yaml` because that
  # file answers the question the rule actually asks — is a PEER carrying this
  # value RIGHT NOW — in one read. A value that was applied and later reverted
  # or superseded is no longer the peer's applied digest, so "and has not since
  # reverted or superseded it" falls out of the record shape rather than out of
  # a journal replay. Attribution is §7.3's: only `<h>` may write `applied/<h>`.
  while IFS= read -r fleet_run_peer; do
    [ -n "$fleet_run_peer" ] || continue
    [ "$fleet_run_peer" != "$2" ] || continue
    [ "$(fleet_applied_digest "$1" "$fleet_run_peer" "$3")" != "$4" ] ||
      return 0
  done <"$5"
  return 1
}

fleet_run_journal_at() {
  # fleet_run_journal_at STORE ITEM DIGEST HOSTS_FILE -> the newest `at` any
  # host recorded applying this value, ISO8601 Z, or nothing.
  #
  # The journal `at`, NEVER `committer.timestamp()`: JJ_TIMESTAMP produces
  # exactly that committer timestamp, so one host with a deliberate future
  # stamp would win every rule-5 contest forever. Journal `at` is what §10.7's
  # 5-minute skew check already covers.
  while IFS= read -r fleet_run_peer; do
    [ -n "$fleet_run_peer" ] || continue
    fleet_journal_entries "$1" "$fleet_run_peer" |
      jq -r --arg item "$2" --arg digest "$3" \
        'select(.item == $item and .digest == $digest and .outcome == "applied") | .at'
  done <"$4" | LC_ALL=C sort | tail -1
}

fleet_run_revert_evidence() {
  # fleet_run_revert_evidence STORE REV ITEM HOST WORKDIR -> two JSON lines:
  # what the change this side NAMES replaced, and what that same change set.
  #
  # Read from HISTORY at <c>- and <c>, never from the trailer. The trailer is
  # only a pointer to what to check: a hostile enrolled host can write
  # `roundhouse-reverts` into a commit that is not a revert, and §8.2b rule 3
  # is what stops that claim winning anything.
  fleet_run_claim=$(fleet_run_trailer "$1" "$2" roundhouse-reverts)
  [ -n "$fleet_run_claim" ] || {
    printf 'null\nnull\n'
    return
  }
  fleet_run_named=$(jj -R "$1" log -r "$fleet_run_claim" --no-graph \
    -T 'commit_id' 2>/dev/null) || fleet_run_named=
  [ -n "$fleet_run_named" ] || {
    printf 'null\nnull\n'
    return
  }
  for fleet_run_side in "$fleet_run_named-" "$fleet_run_named"; do
    rm -rf "$5/claim"
    fleet_run_export "$1" "$fleet_run_side" "$5/claim" 2>/dev/null || :
    fleet_run_claim_fold=$(fleet_fold "$5/claim" "$4" 2>/dev/null) ||
      fleet_run_claim_fold='{}'
    fleet_run_claim_value=$(fleet_item_value "$fleet_run_claim_fold" "$3")
    printf '%s\n' "${fleet_run_claim_value:-null}"
  done
}

fleet_run_evidence() {
  # fleet_run_evidence ITEM INTERVAL MINE_JSON THEIRS_JSON -> §8.2b's evidence
  # document. The split between `grounded` and `asserted` is the safety
  # property, not documentation: signed history and replicated journals are
  # grounded, the §5 trailers are self-asserted, and only rule 2 reads the
  # third class.
  jq -cn --arg item "$1" --argjson interval "$2" \
    --argjson mine "$3" --argjson theirs "$4" \
    '{item:$item,fast_interval_seconds:$interval,mine:$mine,theirs:$theirs}'
}

fleet_run_side() {
  # fleet_run_side STORE REV ITEM HOST HOSTS_FILE WORKDIR LAYERDIR [OTHER-REV]
  # -> one side's `{grounded, asserted}`. OTHER-REV bounds the range the
  # session trailer is read over; see fleet_run_side_session.
  fleet_run_fold=$(fleet_fold "$7" "$4" 2>/dev/null) || fleet_run_fold='{}'
  fleet_run_value=$(fleet_item_value "$fleet_run_fold" "$3")
  fleet_run_value=${fleet_run_value:-null}
  fleet_run_digest=
  [ "$fleet_run_value" = null ] ||
    fleet_run_digest=$(printf '%s\n' "$fleet_run_value" |
      fleet_value_digest "$3" 2>/dev/null) || fleet_run_digest=
  fleet_run_claims=$(fleet_run_revert_evidence "$1" "$2" "$3" "$4" "$6")
  fleet_run_applied=false
  [ -z "$fleet_run_digest" ] ||
    ! fleet_run_applied_elsewhere "$1" "$4" "$3" "$fleet_run_digest" "$5" ||
    fleet_run_applied=true
  fleet_run_at=
  [ -z "$fleet_run_digest" ] ||
    fleet_run_at=$(fleet_run_journal_at "$1" "$3" "$fleet_run_digest" "$5")
  jq -cn --argjson value "$fleet_run_value" \
    --argjson replaced "$(printf '%s\n' "$fleet_run_claims" | sed -n 1p)" \
    --argjson set_to "$(printf '%s\n' "$fleet_run_claims" | sed -n 2p)" \
    --argjson applied "$fleet_run_applied" \
    --arg at "${fleet_run_at:-}" \
    --arg session "$(fleet_run_side_session "$1" "$2" "${8:-}")" \
    --arg host "$(fleet_run_trailer "$1" "$2" roundhouse-host)" \
    --arg intent "$(fleet_run_trailer "$1" "$2" roundhouse-intent)" \
    --arg reverts "$(fleet_run_trailer "$1" "$2" roundhouse-reverts)" \
    '{grounded: {value: $value, revert_replaced: $replaced,
                 revert_set_to: $set_to, applied_elsewhere: $applied,
                 journal_at: (if $at == "" then null else $at end)},
      asserted: {session: $session, host: $host, intent: $intent,
                 reverts: $reverts}}'
}

# --- §10.1/§10.3/§10.8: the gates between a verdict and an apply --------------

fleet_run_canary_hosts() {
  # fleet_run_canary_hosts LAYERDIR GROUP HOSTS_FILE — membership is a grep
  # across the host files (§10.1's own stated ceiling: at ~30 hosts it moves
  # into groups/canary.yaml).
  # An `if`, not an `&&` chain: a `while` loop's status is that of the last
  # command its body ran, so a final non-canary host would fail the whole
  # function under `set -e`.
  while IFS= read -r fleet_run_host; do
    [ -n "$fleet_run_host" ] || continue
    if fleet_host_facts "$1" "$fleet_run_host" 2>/dev/null |
      jq -e --arg g "$2" '(.groups // []) | index($g) != null' >/dev/null 2>&1; then
      printf '%s\n' "$fleet_run_host"
    fi
  done <"$3"
}

fleet_run_is_revert() {
  # fleet_run_is_revert STORE HOST ITEM DIGEST — §10.8's revert-signature
  # predicate, wired to this host's OWN journal. A stored verdict does not
  # satisfy the apply gate when the incoming digest is one this host previously
  # applied and later stopped applying: applied, then withdrawn, now back IS
  # the signature of a revert, and without this a verdict keyed on (item,
  # digest) matches a stale pass and auto-applies the rollback with no review.
  fleet_vcs_journal_outcomes "$1/journal/$2" "$3" |
    fleet_vcs_revert_signature "$4"
}

# --- the apply layer ----------------------------------------------------------

fleet_run_ssh_include() {
  # §5's rendered aliases reach ssh only if ~/.ssh/config includes them. One
  # line, idempotent, FIRST in the file because ssh_config takes the first
  # value it sees for every keyword and a later Include cannot win.
  #
  # This is the one host mutation the fold deliberately left out: rendering is
  # pure (lib/fleet-fold.sh), wiring the render into the host is a run step.
  fleet_run_ssh_dir=$HOME/.ssh
  fleet_run_ssh_config=$fleet_run_ssh_dir/config
  fleet_run_include="Include $fleet_run_ssh_dir/config.d/roundhouse"
  mkdir -p "$fleet_run_ssh_dir/config.d"
  chmod 700 "$fleet_run_ssh_dir" 2>/dev/null || :
  [ -f "$fleet_run_ssh_config" ] || : >"$fleet_run_ssh_config"
  grep -Fqx "$fleet_run_include" "$fleet_run_ssh_config" && return 0
  fleet_run_ssh_tmp=$(mktemp "${TMPDIR:-/tmp}/roundhouse-ssh-include.XXXXXX") ||
    return 1
  printf '%s\n' "$fleet_run_include" >"$fleet_run_ssh_tmp"
  cat "$fleet_run_ssh_config" >>"$fleet_run_ssh_tmp"
  safe_output "$fleet_run_ssh_tmp" "$fleet_run_ssh_config"
  rm -f "$fleet_run_ssh_tmp"
}

fleet_run_state_of() {
  # §4's reader's choice: a scalar IS the state, a map carries it under
  # `state:`, and a map that states none at all defaults to enabled.
  #
  # `has("state")` rather than `.state // "enabled"`: jq's alternative operator
  # treats FALSE and NULL alike, so `state: false` — a plausible hand-edit —
  # read as ABSENT and therefore as `enabled`, quietly turning a stop into a
  # start. lib/fleet-run.sh's own seeder carries this same warning about
  # `.enabled // true`. Returning the value verbatim lets the apply layer's
  # guard hold anything that is not `enabled`/`disabled`.
  printf '%s\n' "$1" |
    jq -r 'if type == "object" then (if has("state") then .state else "enabled" end)
      else . end'
}

fleet_config_drift() {
  # fleet_config_drift HOST FILE VALUE — §6/convergence.md's read-only
  # managed-key drift report. For each key this fleet declares `managed` in the
  # config file, read its CURRENT on-disk value and print it. Changes nothing:
  # `config_files` owns keys, not values (§5 defers value convergence), so there
  # is no stored desired value to compare against or restore — the report exists
  # so a hand-edit to a managed key is SEEN, never silently reverted.
  fleet_run_cf_file=$2
  fleet_run_cf_path=$(expand_user_path "$fleet_run_cf_file")
  printf '%s\n' "$3" |
    jq -r '(.keys // {}) | to_entries[] | select(.value == "managed") | .key' \
      2>/dev/null |
    while IFS= read -r fleet_run_cf_key; do
      [ -n "$fleet_run_cf_key" ] || continue
      if [ ! -f "$fleet_run_cf_path" ]; then
        printf '  drift  config_files.%s %s  on-disk=<file absent>\n' \
          "$fleet_run_cf_file" "$fleet_run_cf_key"
        continue
      fi
      # `getpath(split("."))` reads the dotted managed key; an absent key reads
      # as `null`, a file that does not parse as `<unreadable>` — both reported,
      # neither changed.
      fleet_run_cf_on=$(FLEET_CF_KEY=$fleet_run_cf_key jq -c \
        'getpath(env.FLEET_CF_KEY | split("."))' "$fleet_run_cf_path" 2>/dev/null) ||
        fleet_run_cf_on='<unreadable>'
      [ -n "$fleet_run_cf_on" ] || fleet_run_cf_on='<unreadable>'
      printf '  drift  config_files.%s %s  on-disk=%s\n' \
        "$fleet_run_cf_file" "$fleet_run_cf_key" "$fleet_run_cf_on"
    done
}

fleet_run_plugin_enabled() {
  # State verbs reject no-ops; verify one strict user-scoped manager row.
  # A bare id can resolve to more than one marketplace, which is not proof.
  # The optional second argument is only for the pre-verb transition probe:
  # an absent row is `unknown` there, while the post-verb proof still holds.
  fleet_run_allow_absent=${2:-false}
  # A list that fails or times out is transient (74); a list that answers
  # without one clear row is not (75).
  fleet_run_plugin_list=$(fleet_run_cli_cached installed \
    claude plugin list --json 2>/dev/null) || return 74
  fleet_run_plugin_state=$(printf '%s\n' "$fleet_run_plugin_list" |
    jq -e -r --arg id "$1" --argjson allow_absent "$fleet_run_allow_absent" '
      def records:
        if type == "array" then .
        elif type == "object" and (.installed | type == "array") then .installed
        else error("invalid plugin list")
        end;
      [ records[]
        | select(.scope == "user")
        | (.id // .pluginId) as $record_id
        | select(($record_id | type) == "string")
        | select(if ($id | contains("@")) then $record_id == $id
                 else ($record_id | split("@")[0]) == $id
                 end) ] as $matches
      | if ($matches | length) == 0 and $allow_absent then "unknown"
        elif ($matches | length) == 1 and ($matches[0].enabled | type == "boolean")
        then ($matches[0].enabled | tostring)
        else empty
        end' 2>/dev/null) || return 75
  printf '%s\n' "$fleet_run_plugin_state"
}

fleet_run_approve_plugin_hooks() {
  # The DSC plugin item is a Claude manager operation, but the hook trust state
  # is Codex-local. Qualified marketplace IDs are the shared seam accepted by
  # codex-plugin-hooks.mjs; an unqualified Claude-only name has no Codex
  # identity to approve and remains on the native manager path.
  case ${1:-} in
    *@*) ;;
    *) return 0 ;;
  esac
  fleet_run_expected_sha=${2:-}
  [ -z "$fleet_run_expected_sha" ] ||
    printf '%s\n' "$fleet_run_expected_sha" | grep -Eq '^[0-9a-fA-F]{40}$' ||
    return 75
  # Claude's marketplace namespace is not proof that Codex owns the same
  # plugin. A Claude-only install has no Codex hook trust state to mutate;
  # asking the helper to approve it would turn a successful Claude apply into
  # a false hold. If Codex is present, a malformed/failed list is a real
  # inability to prove ownership and remains held.
  command -v codex >/dev/null 2>&1 || return 0
  # A failed listing is transient (74): kept, so the next fast pass retries.
  fleet_run_codex_plugin_state=$(fleet_run_codex_record_state "$1" '') || return $?
  [ "$fleet_run_codex_plugin_state" != absent ] || return 0
  # Codex's registration is the operator's, not the item's: a Codex copy
  # someone DISABLED runs no hooks, so there is nothing to approve, and it is
  # never reinstalled (`codex plugin add` would re-enable it).
  fleet_run_codex_rec=$(fleet_run_codex_record "$1") || return $?
  fleet_run_codex_enabled=$(printf '%s\n' "$fleet_run_codex_rec" | jq -r '.enabled == true') ||
    return 75
  [ "$fleet_run_codex_enabled" = true ] || return 0
  fleet_run_hooks_node=$(fleet_node_path) || {
    printf 'roundhouse: Node.js is required to approve hooks for %s\n' "$1" >&2
    return 75
  }
  # Third argument `refresh`: called right after an install or update of an
  # ENABLED plugin. The run never reinstalls Codex's copy (no
  # `codex-plugin-hooks.mjs update` here: it would re-trust refreshed hooks
  # before any check below could refuse, and a 75 undoes no trust write).
  # Codex's own startup sync, which the pass triggers before this loop,
  # brings the copy current; approval is byte-verified in one session. A
  # copy from another source sharing the ID, or one Codex has not synced to
  # the expected SHA yet, holds with its reason, and the next pass retries.
  if [ "${3:-}" = refresh ]; then
    fleet_run_codex_source_ok "$1" || {
      printf "roundhouse: automatic hook approval for %s refused: Codex's copy is not from the source Claude's catalog names\n" "$1" >&2
      return 75
    }
  fi
  fleet_run_codex_plugin_state=$(fleet_run_codex_record_state "$1" \
    "$fleet_run_expected_sha") || return 75
  case $fleet_run_codex_plugin_state in
    match) ;;
    local)
      fleet_run_codex_bytes_verified "$1" "$fleet_run_expected_sha" || {
        printf 'roundhouse: automatic hook approval for %s refused: %s\n' \
          "$1" "$fleet_run_bytes_reason" >&2
        return 75
      }
      ;;
    *)
      printf 'roundhouse: automatic hook approval for %s refused: Codex has not synced to %s yet; the next pass retries\n' \
        "$1" "${fleet_run_expected_sha:-the expected bytes}" >&2
      return 75
      ;;
  esac
  # Codex advances its own copies (its startup sync), so a hook this host
  # trusted reads `modified` once upstream changed it. Automatic approval
  # carries that trust only for bytes PROVEN to be the verified upstream ones
  # (fleet_run_codex_bytes_verified); otherwise the helper refuses a modified
  # hook, and a never-trusted hook is refused either way.
  # The verified IDENTITY goes to the helper, not a bare yes: it re-checks
  # the SHA and the two trees, and that the hooks it writes are the ones it
  # listed, inside the one app server session that writes trust.
  fleet_run_hook_sha=
  fleet_run_hook_tree=
  fleet_run_hook_codex_tree=
  fleet_run_hook_source_path=
  fleet_run_bytes_reason=
  if [ -n "$fleet_run_expected_sha" ] &&
    fleet_run_codex_bytes_verified "$1" "$fleet_run_expected_sha"; then
    fleet_run_hook_sha=$fleet_run_expected_sha
    fleet_run_hook_tree=$fleet_run_bv_claude_path
    fleet_run_hook_codex_tree=$fleet_run_bv_codex_path
    fleet_run_hook_source_path=$fleet_run_bv_local_path
  fi
  fleet_run_cli_invalidate
  ROUNDHOUSE_AUTOMATIC_HOOK_APPROVAL=1 \
    ROUNDHOUSE_VERIFIED_SHA=$fleet_run_hook_sha \
    ROUNDHOUSE_VERIFIED_TREE=$fleet_run_hook_tree \
    ROUNDHOUSE_CODEX_TREE=$fleet_run_hook_codex_tree \
    ROUNDHOUSE_CODEX_SOURCE_PATH=$fleet_run_hook_source_path \
    "$fleet_run_hooks_node" "$script_dir/codex-plugin-hooks.mjs" approve "$1" \
    >/dev/null || {
    [ -z "$fleet_run_bytes_reason" ] ||
      printf 'roundhouse: automatic hook approval for %s carried no trust: %s\n' \
        "$1" "$fleet_run_bytes_reason" >&2
    return 75
  }
}

fleet_run_codex_bytes_verified() {
  # fleet_run_codex_bytes_verified ID SHA — exit 0 when Codex's installed
  # copy of ID is byte-identical to Claude's verified install at SHA: the
  # Codex record comes from the intended source (fleet_run_codex_source_ok)
  # at SHA, Claude's user-scoped install is at SHA, and the two installed
  # trees hash the same under fleet_run_tree_digest (the same digest and
  # exclusions the relative-source identity uses). Otherwise 1, with the
  # cause in `fleet_run_bytes_reason`.
  fleet_run_bytes_reason=
  fleet_run_codex_source_ok "$1" || {
    fleet_run_bytes_reason="Codex's copy is not from the source Claude's catalog names"
    return 1
  }
  fleet_run_bv_record=$(fleet_run_codex_record "$1") || {
    fleet_run_bytes_reason='the Codex plugin list is unreadable'
    return 1
  }
  fleet_run_bv_fields=$(printf '%s\n' "$fleet_run_bv_record" | jq -r '
    [(.source.sha // ""), (.marketplaceName // ""), (.name // ""), (.version // ""),
      (.source.source // ""), (.source.path // "")] |
    map(tostring) | join("\u001f")') || fleet_run_bv_fields=
  IFS=$fleet_run_sep read -r fleet_run_bv_sha fleet_run_bv_market fleet_run_bv_name \
    fleet_run_bv_version fleet_run_bv_kind fleet_run_bv_srcpath <<EOF
$fleet_run_bv_fields
EOF
  # A git-sourced record carries the SHA it was installed at. A local
  # (in-marketplace) one carries none: its path inside the verified
  # marketplace root was proven above (fleet_run_codex_source_ok), and the
  # byte comparison below is its identity.
  fleet_run_bv_local_path=
  if [ "$fleet_run_bv_kind" = local ] && [ -z "$fleet_run_bv_sha" ]; then
    fleet_run_bv_local_path=$fleet_run_bv_srcpath
  elif [ "$fleet_run_bv_sha" != "$2" ]; then
    fleet_run_bytes_reason="Codex's copy is at ${fleet_run_bv_sha:-no SHA}, not $2"
    return 1
  fi
  fleet_run_bv_claude=$(fleet_run_installed_plugin "$1" 2>/dev/null) || fleet_run_bv_claude='{}'
  fleet_run_bv_claude_path=$(printf '%s\n' "$fleet_run_bv_claude" | jq -r --arg sha "$2" '
    if (.gitCommitSha // "") == $sha then (.installPath // "") else "" end') ||
    fleet_run_bv_claude_path=
  [ -n "$fleet_run_bv_claude_path" ] && [ -d "$fleet_run_bv_claude_path" ] || {
    fleet_run_bytes_reason="no Claude install of $1 at $2 to compare against"
    return 1
  }
  for fleet_run_bv_part in "$fleet_run_bv_market" "$fleet_run_bv_name" "$fleet_run_bv_version"; do
    case $fleet_run_bv_part in '' | . | .. | */*) fleet_run_bytes_reason="Codex's record names no installed copy"; return 1 ;; esac
  done
  fleet_run_bv_codex_path="${CODEX_HOME:-$HOME/.codex}/plugins/cache/$fleet_run_bv_market/$fleet_run_bv_name/$fleet_run_bv_version"
  [ -d "$fleet_run_bv_codex_path" ] || {
    fleet_run_bytes_reason="Codex's installed copy is missing at $fleet_run_bv_codex_path"
    return 1
  }
  fleet_run_bv_want=$(fleet_run_tree_digest "$fleet_run_bv_claude_path") || {
    fleet_run_bytes_reason="Claude's install of $1 could not be hashed"
    return 1
  }
  fleet_run_bv_have=$(fleet_run_tree_digest "$fleet_run_bv_codex_path") || {
    fleet_run_bytes_reason="Codex's installed copy of $1 could not be hashed"
    return 1
  }
  [ "$fleet_run_bv_want" = "$fleet_run_bv_have" ] || {
    fleet_run_bytes_reason="Codex's installed copy of $1 differs byte-for-byte from Claude's verified install at $2"
    return 1
  }
}

fleet_run_codex_hooks_settled() {
  # fleet_run_codex_hooks_settled ID SHA — exit 0 when Codex's copy of an
  # enabled fleet plugin needs nothing: Codex does not have it (or has it
  # disabled), or its copy is at SHA with every hook trusted. Read-only until
  # it finds work: a `modified` hook retries the byte-verified approval; a
  # copy not at SHA, or a hook never trusted (which needs the operator), holds
  # (75) with its reason, so the next pass asks again.
  case ${1:-} in *@*) ;; *) return 0 ;; esac
  command -v codex >/dev/null 2>&1 || return 0
  fleet_run_hs_record=$(fleet_run_codex_record "$1") || return $?
  [ "$(printf '%s\n' "$fleet_run_hs_record" | jq -r '.enabled == true')" = true ] || return 0
  if [ -n "${2:-}" ] && [ "$(printf '%s\n' "$fleet_run_hs_record" | jq -r '.source.sha // ""')" != "$2" ]; then
    # A local (in-marketplace) record has no SHA: it is synced when it is
    # from the verified source and byte-identical to Claude's install.
    if [ "$(fleet_run_codex_record_state "$1" "$2")" = local ]; then
      fleet_run_codex_bytes_verified "$1" "$2" || {
        printf 'roundhouse: Codex hooks for %s are not approved: %s; the next pass retries\n' \
          "$1" "$fleet_run_bytes_reason" >&2
        return 75
      }
    else
      printf 'roundhouse: Codex hooks for %s are not approved: Codex has not synced to %s yet; the next pass retries\n' \
        "$1" "$2" >&2
      return 75
    fi
  fi
  fleet_run_hs_node=$(fleet_node_path) || return 75
  fleet_run_hs_status=$(bounded_query "$fleet_run_hs_node" "$script_dir/codex-plugin-hooks.mjs" \
    status "$1" 2>/dev/null </dev/null) || return 74
  fleet_run_hs_counts=$(printf '%s\n' "$fleet_run_hs_status" |
    jq -er '"\(.modified | numbers) \(.untrusted | numbers)"' 2>/dev/null) || return 75
  case $fleet_run_hs_counts in
    '0 0') return 0 ;;
    *' 0') fleet_run_approve_plugin_hooks "$1" "${2:-}" refresh ;;
    *)
      printf 'roundhouse: Codex hooks for %s are not approved: a hook was never trusted; approve it explicitly (approve-codex-plugin-hooks)\n' \
        "$1" >&2
      return 75
      ;;
  esac
}

fleet_run_codex_record() {
  # fleet_run_codex_record ID -> Codex's installed record for ID as compact
  # JSON (`{}` when there is none). Exit 75 when the list cannot be read.
  fleet_run_codex_plugins=$(fleet_run_cli_cached codex \
    codex plugin list --json 2>/dev/null) || return 74
  printf '%s\n' "$fleet_run_codex_plugins" | jq -e -c --arg id "$1" '
    if type == "array" then .
    elif type == "object" and (.installed | type == "array") then .installed
    else error("invalid plugin list") end |
    [.[] | objects | select((.pluginId // .id) == $id and (.installed != false))] |
    (.[0] // {})' 2>/dev/null || return 75
}

fleet_run_codex_source_ok() {
  # fleet_run_codex_source_ok ID — exit 0 when Codex's installed copy of ID
  # comes from the plugin source Claude's catalog names (any revision of it),
  # 75 otherwise or when that cannot be shown. Two catalog shapes:
  #   - a source with a repository (`git`/`git-subdir`/`url`/`github`): the
  #     same repository, GitHub spellings folded together, and the same path
  #     inside it;
  #   - a relative, in-marketplace source: the Codex marketplace the record
  #     belongs to is registered from the same repository Claude's is, and
  #     the record's local path is that relative path under its root.
  fleet_run_cso_catalog=$(fleet_run_plugin_catalog_proven "$1") || return 75
  fleet_run_cso_record=$(fleet_run_codex_record "$1") || return 75
  fleet_run_cso_srcid='
    def repo: sub("/+$"; "") |
      if test("^(https://|ssh://git@|git@)github[.]com[:/]") then
        "github:" + (sub("^(https://|ssh://git@|git@)github[.]com[:/]"; "") |
          ascii_downcase | sub("[.]git$"; ""))
      else sub("[.]git$"; "") end;
    def rel: (. // "") | tostring | sub("^[.]/"; "") | sub("^[.]$"; "") | sub("/+$"; "");
    def srcid: (if .source == "github" then "https://github.com/" + (.repo // "")
      else (.url // "") end) as $u |
      if ($u | type) == "string" and $u != "" then ($u | repo) + "|" + (.path | rel)
      else empty end;'
  fleet_run_cso_kind=$(printf '%s\n' "$fleet_run_cso_catalog" |
    jq -r '.source.source // ""') || return 75
  if [ "$fleet_run_cso_kind" != relative ]; then
    fleet_run_cso_want=$(printf '%s\n' "$fleet_run_cso_catalog" |
      jq -er "$fleet_run_cso_srcid"' .source | srcid' 2>/dev/null) || return 75
    fleet_run_cso_have=$(printf '%s\n' "$fleet_run_cso_record" |
      jq -er "$fleet_run_cso_srcid"' .source | srcid' 2>/dev/null) || return 75
    [ "$fleet_run_cso_want" = "$fleet_run_cso_have" ]
    return
  fi
  # In-marketplace: compare the two marketplaces' repositories, then the path.
  fleet_run_cso_market=${1##*@}
  fleet_run_cso_centry=$(fleet_run_marketplaces | jq -c --arg n "$fleet_run_cso_market" \
    '[.[] | select(.name == $n)] | .[0] // empty' 2>/dev/null) || return 75
  [ -n "$fleet_run_cso_centry" ] || return 75
  fleet_run_cso_claude=$(fleet_run_marketplace_registered_locator "$fleet_run_cso_market" \
    "$fleet_run_cso_centry") || return 75
  fleet_run_cso_xmarket=$(printf '%s\n' "$fleet_run_cso_record" |
    jq -r '.marketplaceName // empty') || return 75
  fleet_run_cso_xentry=$(bounded_query codex plugin marketplace list --json 2>/dev/null |
    jq -ec --arg n "$fleet_run_cso_xmarket" '
      (if type == "array" then . else (.marketplaces // []) end) |
      [.[] | select(.name == $n)] | .[0] // error("none")' 2>/dev/null) || return 75
  fleet_run_cso_codex=$(printf '%s\n' "$fleet_run_cso_xentry" | jq -r \
    "$fleet_run_marketplace_locator_filter"'
    {source: {source: "git", url: (.marketplaceSource.source // "")}} | locator') ||
    return 75
  # A ref is not part of this comparison: an older revision of the same
  # repository is the same source.
  [ "${fleet_run_cso_claude%%#*}" = "${fleet_run_cso_codex%%#*}" ] || return 75
  printf '%s\n' "$fleet_run_cso_xentry" "$fleet_run_cso_record" \
    "$fleet_run_cso_catalog" | jq -es '
      def norm: tostring | gsub("/+"; "/") | sub("/$"; "") | sub("/[.]$"; "");
      def rel: (. // "") | tostring | sub("^[.]/"; "") | sub("^[.]$"; "") | sub("/+$"; "");
      .[0].root as $root | .[1].source as $s | (.[2].source.path | rel) as $rel |
      ($root | type) == "string" and ($s.source // "") == "local" and
      (($s.path // "") | norm) ==
        (if $rel == "" then $root else $root + "/" + $rel end | norm)' \
    >/dev/null 2>&1 || return 75
}

fleet_run_codex_record_state() {
  # fleet_run_codex_record_state ID EXPECTED-SHA -> `absent` when Codex has no
  # installed record for ID, else `match` or `mismatch` against EXPECTED-SHA
  # (an empty one matches any record). Exit 75 when the list cannot be read.
  fleet_run_codex_plugins=$(fleet_run_cli_cached codex \
    codex plugin list --json 2>/dev/null) || return 74
  printf '%s\n' "$fleet_run_codex_plugins" | jq -e -r \
    --arg id "$1" --arg expected_sha "$2" '
    def records:
      if type == "array" then .
      elif type == "object" and (.installed | type == "array") then .installed
      else error("invalid plugin list")
      end;
    [records[] | select((.pluginId // .id) == $id and (.installed != false))] as $matches |
      if ($matches | length) == 0 then "absent"
      elif $expected_sha == "" or any($matches[]; .source.sha == $expected_sha)
      then "match"
      # An in-marketplace plugin: Codex records `source: local` with no SHA,
      # so its identity is its path and bytes (fleet_run_codex_bytes_verified).
      elif any($matches[]; .source.source == "local" and (.source.sha // "") == "")
      then "local"
      else "mismatch"
      end
  ' 2>/dev/null || return 75
}

fleet_run_skill_source_identity() {
  # Compare skills.sh's GitHub shorthand and equivalent Git remote spellings.
  printf '%s\n' "$1" | sed -E \
    -e 's#^git@([^:]+):#https://\1/#' \
    -e 's#^ssh://(git@)?#https://#' \
    -e 's#^([^/:]+/[^/:]+)$#https://github.com/\1#' \
    -e 's#/$##' -e 's#\.git$##'
}

fleet_run_skill_exposed() (
  # Roots can be alternatives for one harness. Accept configured exposure or
  # the manager's native location, including Codex's universal directory.
  #
  # The roots are the host's, the same for every skill, so inside the run
  # loop the agent list and each agent's expanded root paths — computed by
  # the very jq reads below — are kept for the run, and each further skill
  # costs only its file tests.
  exposed_memo=
  if [ -n "${fleet_run_apply_ctx:-}" ]; then
    exposed_memo=$fleet_run_apply_ctx/exposed
    if [ ! -f "$exposed_memo/roots" ] || [ "$(cat "$exposed_memo/roots")" != "$2" ]; then
      fleet_run_skill_exposure_memo "$exposed_memo" "$2" || exposed_memo=
    fi
  fi
  if [ -n "$exposed_memo" ]; then
    [ ! -f "$exposed_memo/agents.failed" ] || return 75
    exposed_agents=$(cat "$exposed_memo/agents")
  else
    exposed_agents=$(printf '%s\n' "$2" | jq -rs '[.[].agents[]?] | unique | .[]') || return 75
  fi
  [ -n "$exposed_agents" ] || return 75
  for exposed_agent in $exposed_agents; do
    case $exposed_agent in
      codex) exposed_native="$HOME/.agents/skills" ;;
      claude) exposed_native="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills" ;;
      *) return 75 ;;
    esac
    [ ! -f "$exposed_native/$1/SKILL.md" ] || continue
    exposed=false
    if [ -n "$exposed_memo" ]; then
      while IFS= read -r exposed_path; do
        [ ! -f "$exposed_path/$1/SKILL.md" ] || exposed=true
      done <"$exposed_memo/paths.$exposed_agent"
    else
      while IFS= read -r exposed_root; do
        printf '%s\n' "$exposed_root" | jq -e --arg agent "$exposed_agent" \
          '(.agents // []) | index($agent) != null' >/dev/null || continue
        exposed_path=$(expand_user_path "$(printf '%s\n' "$exposed_root" | jq -r '.path')")
        [ ! -f "$exposed_path/$1/SKILL.md" ] || exposed=true
      done <<EOF
$2
EOF
    fi
    [ "$exposed" = true ] || return 75
  done
)

fleet_run_skill_exposure_memo() {
  # fleet_run_skill_exposure_memo DIR ROOTS — what fleet_run_skill_exposed
  # reads from ROOTS, by its own jq calls, once: the agent list (or that the
  # read failed), and per agent the expanded path of every root naming it.
  # Non-zero, and no memo, when a path would not survive a line-based file.
  rm -rf "$1"
  mkdir -p "$1" || return 1
  if ! exposure_agents=$(printf '%s\n' "$2" | jq -rs '[.[].agents[]?] | unique | .[]'); then
    : >"$1/agents.failed"
    printf '%s\n' "$2" >"$1/roots"
    return 0
  fi
  printf '%s\n' "$exposure_agents" >"$1/agents"
  for exposure_agent in $exposure_agents; do
    case $exposure_agent in codex | claude) ;; *) continue ;; esac
    : >"$1/paths.$exposure_agent"
    while IFS= read -r exposure_root; do
      printf '%s\n' "$exposure_root" | jq -e --arg agent "$exposure_agent" \
        '(.agents // []) | index($agent) != null' >/dev/null || continue
      exposure_path=$(expand_user_path "$(printf '%s\n' "$exposure_root" | jq -r '.path')")
      case $exposure_path in *"
"*) rm -rf "$1"; return 1 ;; esac
      printf '%s\n' "$exposure_path" >>"$1/paths.$exposure_agent"
    done <<EOF
$2
EOF
  done
  printf '%s\n' "$2" >"$1/roots"
}

fleet_run_install_skill() (
  # Keep skills.sh's canonical installation and lock intact. Both standalone
  # repositories and collections go through its explicit skill selector.
  skill_name=$1
  skill_source=$2
  printf '%s\n' "$skill_name" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$' || return 75
  skill_lock="$HOME/.agents/.skill-lock.json"
  skill_canonical="$HOME/.agents/skills/$skill_name"
  if [ -f "$skill_lock" ]; then
    # Kept for the run loop until something rewrites the lock (the install
    # below invalidates it).
    fleet_run_cli_cached skill-lock-shape \
      jq -e '(.skills // .) | type == "object"' "$skill_lock" >/dev/null 2>&1 || return 75
    skill_locked_source=$(jq -r --arg name "$skill_name" \
      '(.skills // .)[$name] | .sourceUrl // .source // empty' "$skill_lock") || return 75
    if [ -n "$skill_source" ] && [ -n "$skill_locked_source" ]; then
      [ "$(fleet_run_skill_source_identity "$skill_source")" = \
        "$(fleet_run_skill_source_identity "$skill_locked_source")" ] || return 75
    fi
  fi
  skill_roots=$(fleet_run_cli_cached "skill-roots.$3" jq -c --arg host "$3" '
    (.machines[$host].groups // []) as $host_groups |
    (.skill_roots // [])[] |
    select((.groups // []) as $groups | ($groups | length) == 0 or
      any($groups[]; . as $group | $host_groups | index($group) != null))' \
    "$(config_path)" 2>/dev/null) || return 75
  if [ -f "$skill_canonical/SKILL.md" ]; then
    fleet_run_skill_exposed "$skill_name" "$skill_roots"
    return $?
  fi
  while IFS= read -r skill_root; do
    [ -n "$skill_root" ] || continue
    skill_path=$(expand_user_path "$(printf '%s\n' "$skill_root" | jq -r '.path')")
    # -f follows valid manager symlinks; an empty directory is not a skill.
    if [ -f "$skill_path/$skill_name/SKILL.md" ]; then
      fleet_run_skill_exposed "$skill_name" "$skill_roots"
      return $?
    fi
  done <<EOF
$skill_roots
EOF
  fleet_validate_fetch_url "$skill_source" || return 75
  command -v npx >/dev/null 2>&1 || return 75
  skill_agents=$(printf '%s\n' "$skill_roots" | jq -rs '
    [.[].agents[]? | select(. == "codex" or . == "claude") |
      if . == "claude" then "claude-code" else . end] | unique | .[]') || return 75
  [ -n "$skill_agents" ] || return 75
  set -- skills add "$skill_source" --skill "$skill_name" --full-depth --global --yes --agent
  # Only the two fixed manager agent identifiers above enter this word split.
  for skill_agent in $skill_agents; do set -- "$@" "$skill_agent"; done
  fleet_run_cli_invalidate
  # A failed or timed-out `skills add` is transient (74): the next pass
  # retries it. Everything above is a standing "this host cannot" (75).
  bounded_verb npx --yes "$@" >/dev/null 2>&1 || return 74
  [ -f "$skill_canonical/SKILL.md" ] || return 75
  fleet_run_skill_exposed "$skill_name" "$skill_roots" || return 75
  # skills.sh does not write global update records for local-path sources.
  case $skill_source in /* | file:///*) return 0 ;; esac
  jq -e --arg name "$skill_name" '(.skills // .)[$name] | type == "object"' \
      "$skill_lock" >/dev/null 2>&1 || return 75
)

fleet_run_package_managers() {
  # `fleet_run_package_managers FOLD HOST` — the host's managers, in order, as
  # one space-separated line. The fold wins when it states the fact at all
  # (PRESENCE, so an explicit `[]` stays empty). A fold without the key falls
  # back to this host's own config.json — the same source fleet-seed copies
  # from — because the fold is read from the published tree, and a fact the
  # full pass seeds into the working copy only reaches it on the NEXT run.
  # Without the fallback, the first run after upgrading still held every
  # package as unprovidable.
  if printf '%s\n' "$1" | jq -e 'has("package_managers")' >/dev/null 2>&1; then
    printf '%s\n' "$1" | jq -r '(.package_managers // []) | join(" ")'
  else
    jq -r --arg host "$2" '(.machines[$host].package_managers // []) | join(" ")' \
      "$(config_path)" 2>/dev/null || :
  fi
}

fleet_run_node_converge() (
  # `fleet_run_node_converge VALUE DEFS MODE` — bring fnm's default Node to
  # what `runtimes.node` declares (lib/node-runtime.sh). The carry is every
  # installed global (node_switch_plan); DEFS only adds hook requirements.
  #
  #   apply  the reviewed desired-state apply (fast pass, first time or on a
  #          changed value): switch only when the default is outside the
  #          declared major, or is not the pinned version
  #   full   the full cadence: also move to the newest release inside the
  #          major, which fnm never does on its own
  #
  # Exit 0 converged (or already there), 73 deferred to the full cadence (a
  # switch whose hooks failed backs off; fleet_run_apply_held), 75 held with
  # the default untouched or restored (or a switch in progress elsewhere on
  # this host), 76 held
  # with the default UNVERIFIED: a switch is recorded as in flight
  # (interrupted, or failed without a verified restore), so nothing may run
  # npm under the runtime. A recorded switch is handled FIRST, before any
  # "already in line" answer: an interrupted switch is never mistaken for a
  # converged one. Every hold prints a line naming the reason; nothing is
  # ever silently skipped.
  node_value=$1
  node_defs=$2
  node_mode=$3
  [ -n "$node_defs" ] || node_defs='{}'
  node_hold() {
    printf '  hold  runtimes.node — %s\n' "$1"
    exit 75
  }
  node_recover_status=0
  node_switch_recover || node_recover_status=$?
  case $node_recover_status in
    0) ;;
    74) node_hold 'a Node switch is in progress on this host (another run or an apply); not touched this run' ;;
    75) node_hold 'an interrupted switch was rolled back to its old default (verified); it is retried on a later run' ;;
    *)
      printf '  hold  runtimes.node — a switch is recorded in flight (%s) and the old default could not be restored and verified; the fnm default is unverified\n' \
        "$(node_switch_marker_path)"
      exit 76
      ;;
  esac
  node_spec=$(node_runtime_spec "$node_value") ||
    node_hold 'needs `major:` or an exact `version:` (and a version inside that major)'
  node_root=$(node_fnm_root) ||
    node_hold 'no fnm default Node on this host (fnm with a default alias)'
  node_fnm_bin >/dev/null || node_hold 'fnm is not installed on this host'
  node_current=$(node_fnm_default "$node_root") ||
    node_hold "the fnm default alias in $node_root does not name an installed version"
  node_major=$(printf '%s\n' "$node_spec" | jq -r '.major')
  node_pinned=$(printf '%s\n' "$node_spec" | jq -r '.version // empty')
  if [ -n "$node_pinned" ]; then
    [ "$node_current" != "$node_pinned" ] || exit 0
    node_target=$node_pinned
  else
    node_in_line=false
    [ "$(node_version_major "$node_current")" != "$node_major" ] || node_in_line=true
    [ "$node_mode" != apply ] || [ "$node_in_line" != true ] || exit 0
    node_target=$(node_fnm_remote_latest "$node_root" "$node_major") ||
      node_hold "cannot list the published Node $node_major releases"
    if [ "$node_in_line" = true ] && ! release_newer "$node_target" "$node_current"; then
      exit 0
    fi
  fi
  node_detail=$(npm_global_list_detail) ||
    node_hold "the npm global inventory under $node_current failed"
  node_record=$(node_globals_split "$node_detail") ||
    node_hold "the npm global inventory under $node_current is unreadable"
  node_local=$(jq -c '.node_switch_hooks // {}' "$(config_path)" 2>/dev/null) || node_local='{}'
  [ -n "$node_local" ] || node_local='{}'
  node_plan=$(node_switch_plan "$node_record" "$node_target" "$node_defs" "$node_local") ||
    node_hold 'could not compute the npm globals to carry'
  node_plan_held=$(printf '%s\n' "$node_plan" | jq -r '.held // empty')
  [ -z "$node_plan_held" ] || node_hold "$node_plan_held"
  node_plan_carry=$(printf '%s\n' "$node_plan" | jq -c '.carry')
  node_plan_hooks=$(printf '%s\n' "$node_plan" | jq -c '.hooks')
  # A switch whose hooks failed is not flipped again by the reviewed apply
  # until the target, the carry or the hooks change; the full cadence
  # retries it (once per full pass).
  if [ "$node_mode" != full ] &&
    node_switch_backoff_matches "$node_target" "$node_plan_carry" "$node_plan_hooks"; then
    printf '  hold  runtimes.node — %s\n' "the post-switch hooks failed for this exact switch to $node_target; it is retried on the next full pass, or when the target, the carry or the hooks change"
    exit 73
  fi
  printf '  switch runtimes.node %s -> %s (carrying %s)\n' "$node_current" "$node_target" \
    "$(printf '%s\n' "$node_plan" | jq -r '[.carry[] | "\(.name)@\(.version)"] |
      if length == 0 then "no npm globals" else join(" ") end')"
  node_status=0
  node_switch_out=$(node_runtime_switch "$node_target" "$node_plan_carry" "$node_plan_hooks" 2>&1) ||
    node_status=$?
  [ -z "$node_switch_out" ] || printf '%s\n' "$node_switch_out" | sed 's/^/        /'
  [ "$node_status" -ne 75 ] ||
    node_hold 'a Node switch is in progress on this host (another run or an apply); not touched this run'
  node_final=$(node_fnm_default "$node_root" 2>/dev/null) || node_final=
  if ! { [ "$node_status" -eq 0 ] && [ "$node_final" = "$node_target" ] &&
    [ -z "$(node_switch_marker_read)" ]; }; then
    # Never flipped, or flipped and restored with proof, is an ordinary hold.
    # Anything else leaves the switch recorded in flight: a default nobody
    # verified carries the installed globals.
    if [ -z "$(node_switch_marker_read)" ] && [ "$node_final" = "$node_current" ]; then
      node_hold "switch to $node_target failed (see above); the fnm default is still $node_current"
    fi
    printf '  hold  runtimes.node — switch to %s failed and the fnm default (%s) is unverified; the switch stays recorded in flight\n' \
      "$node_target" "${node_final:-unknown}"
    exit 76
  fi
  printf '%s\n' "$node_plan" | jq -r --arg new "$node_target" '
    select(.excluded | length > 0) |
    "  note  runtimes.node — not carried, provided by \($new) itself: \(.excluded | join(" "))"'
  node_stale=$(node_fnm_installed "$node_root" | grep -Fvx "$node_target" | tr '\n' ' ')
  [ -z "$node_stale" ] ||
    printf '  note  runtimes.node — older Node versions remain installed (never removed here): %s\n' \
      "${node_stale% }"
  exit 0
)

# --- the apply loop's per-run context -----------------------------------------
#
# Questions every item of a category asks the same way, answered once per run
# while the loop is open (fleet_run_apply_context_open … _close). Outside the
# loop — `fleet-apply`, the full cadence — every helper below is the plain call
# it wraps.

fleet_run_apply_context_open() {
  # fleet_run_apply_context_open DIR DEFS MANAGERS [PLAN]
  fleet_run_apply_ctx=$1
  mkdir -p "$fleet_run_apply_ctx"
  rm -f "$fleet_run_apply_ctx"/cli.* "$fleet_run_apply_ctx"/brew.*
  # Every packages.* item's resolution, in one jq (fleet_resolve_packages);
  # what it does not decide is resolved per package, as before.
  : >"$fleet_run_apply_ctx/packages"
  fleet_run_apply_ctx_defs=$2
  fleet_run_apply_ctx_managers=$3
  if [ -n "${4:-}" ] && [ -f "$4" ]; then
    LC_ALL=C awk -F"$fleet_run_sep" '$1 == "converge" && $2 ~ /^packages\./ {
        print substr($2, 10) }' "$4" |
      fleet_resolve_packages "$2" "$3" >"$fleet_run_apply_ctx/packages" 2>/dev/null ||
      : >"$fleet_run_apply_ctx/packages"
  fi
}

fleet_run_apply_context_close() {
  fleet_run_apply_ctx=
  fleet_run_apply_ctx_defs=
  fleet_run_apply_ctx_managers=
}

fleet_run_cli_cached() {
  # fleet_run_cli_cached KEY CMD... — CMD's stdout and status. Inside the
  # loop a successful answer is kept under KEY until the next manager verb
  # (fleet_run_cli_invalidate), so `claude plugin list --json` and its kin
  # run once per run instead of three or four times per plugin. A failure is
  # never kept.
  if [ -n "${fleet_run_apply_ctx:-}" ] && [ -f "$fleet_run_apply_ctx/cli.$1" ]; then
    cat "$fleet_run_apply_ctx/cli.$1"
    return 0
  fi
  fleet_run_cli_key=$1
  shift
  fleet_run_cli_out=$(bounded_query "$@") || return
  [ -z "${fleet_run_apply_ctx:-}" ] ||
    printf '%s\n' "$fleet_run_cli_out" >"$fleet_run_apply_ctx/cli.$fleet_run_cli_key" ||
    rm -f "$fleet_run_apply_ctx/cli.$fleet_run_cli_key"
  printf '%s\n' "$fleet_run_cli_out"
}

fleet_run_cli_invalidate() {
  # Called before every verb that changes what the cached lists would say.
  [ -z "${fleet_run_apply_ctx:-}" ] || rm -f "$fleet_run_apply_ctx"/cli.*
}

fleet_run_resolve_package() {
  # fleet_run_resolve_package DEFS NAME MANAGERS — fleet_resolve_package's
  # answer, from the run's batch when it decided this package for these same
  # definitions and managers.
  if [ -n "${fleet_run_apply_ctx:-}" ] && [ "$1" = "$fleet_run_apply_ctx_defs" ] &&
    [ "$3" = "$fleet_run_apply_ctx_managers" ]; then
    fleet_run_rp_line=$(LC_ALL=C awk -F'\t' -v n="$2" '$1 == n { print; exit }' \
      "$fleet_run_apply_ctx/packages")
    if [ -n "$fleet_run_rp_line" ]; then
      printf '%s\n' "${fleet_run_rp_line#*"	"}"
      case $fleet_run_rp_line in
        *'"resolved":true'*) return 0 ;;
        *) return 75 ;;
      esac
    fi
  fi
  # shellcheck disable=SC2086 # the host's package_managers list, in order
  fleet_resolve_package "$1" "$2" $3
}

fleet_run_brew_current() {
  # fleet_run_brew_current MANAGER NAME CASK VERSION — true only when this
  # run's Homebrew snapshot proves `brew install NAME` would change nothing:
  # NAME, untapped, is listed installed (as a cask when CASK is true) and is
  # not in `brew outdated`. Anything else — no snapshot, a snapshot that
  # failed, a tap-qualified or unknown name, an outdated package — answers
  # false, and the caller runs the install exactly as before.
  case $1 in homebrew | linuxbrew) ;; *) return 1 ;; esac
  [ -n "${fleet_run_apply_ctx:-}" ] || return 1
  case $2 in '' | */*) return 1 ;; esac
  if [ ! -f "$fleet_run_apply_ctx/brew.ready" ] &&
    [ ! -f "$fleet_run_apply_ctx/brew.failed" ]; then
    # Outdated names are matched by their last component too: `brew outdated`
    # names a tap formula in full while `brew list` and a definition may not.
    if command -v brew >/dev/null 2>&1 &&
      bounded_query brew list --formula -1 >"$fleet_run_apply_ctx/brew.formulae" 2>/dev/null </dev/null &&
      bounded_query brew list --cask -1 >"$fleet_run_apply_ctx/brew.casks" 2>/dev/null </dev/null &&
      bounded_query brew outdated --json=v2 \
        >"$fleet_run_apply_ctx/brew.outdated.json" 2>/dev/null </dev/null &&
      jq -r '(.formulae, .casks) | arrays | .[].name | strings | ., (split("/") | last)' \
        <"$fleet_run_apply_ctx/brew.outdated.json" >"$fleet_run_apply_ctx/brew.outdated" \
        2>/dev/null &&
      [ -s "$fleet_run_apply_ctx/brew.formulae" ]; then
      : >"$fleet_run_apply_ctx/brew.ready"
    else
      : >"$fleet_run_apply_ctx/brew.failed"
    fi
  fi
  [ -f "$fleet_run_apply_ctx/brew.ready" ] || return 1
  if [ "$3" = true ]; then
    grep -Fqx -- "$2" "$fleet_run_apply_ctx/brew.casks" || return 1
  else
    grep -Fqx -- "$2" "$fleet_run_apply_ctx/brew.formulae" || return 1
  fi
  ! grep -Fqx -- "$2" "$fleet_run_apply_ctx/brew.outdated"
}

fleet_run_apply_item() {
  # fleet_run_apply_item STORE HOST DEFS ITEM VALUE MANAGERS
  #
  # Exit 0 applied, 70 SATISFIED, 75 held, 74 held but transient (and, for
  # runtimes.node, 73 deferred and 76 unverified; fleet_run_node_converge).
  # Presence for manager-installed items
  # is always the manager's own command; only STATE falls back to a config
  # edit, and where a harness has no state verb this design does not invent
  # one.
  #
  # 70 vs 75 is load-bearing and is read by the canary gate, so the split has
  # to mean something a gate can act on:
  #
  #   70 SATISFIED  this design has no state-alignment verb for the item, so
  #                 there is nothing to do — here or on any other host. A no-op
  #                 BECAUSE CORRECT. It journals `satisfied` and counts as
  #                 canary evidence, because gating peers on an `applied`
  #                 record that can never exist deadlocks the item forever and
  #                 buys nothing: the peer would no-op identically.
  #   75 HELD       this host tried and could not, or a gate refused. A no-op
  #                 BECAUSE BLOCKED. It journals `held` and blocks downstream,
  #                 which is the property a genuine apply failure must keep.
  #   74 HELD, TRANSIENT  the same `held`, for an attempt a retry may fix: a
  #                 bounded manager verb or query (`npx skills add`, `claude
  #                 plugin install|update|enable|list`, `claude plugin
  #                 marketplace list`, `codex plugin list`) failed or timed
  #                 out, or a plugin's post-verb re-read did not verify yet.
  #                 The run owes it a retry next pass
  #                 (fleet_run_hold_owes_retry); a 75 waits for the full
  #                 cadence, since only a change elsewhere resolves it. (The
  #                 74 node_switch_recover returns is a different, internal
  #                 status; the runtimes arm folds it into 75.)
  #
  # A miss that is about THIS HOST's capability (no `claude` on the box, no
  # skill root configured, no resolvable source) is 75 and not 70: another host
  # may well be able to apply it, so this host's inability is not evidence
  # about the item.
  #
  # STATE (optional) is fleet_run_state_of VALUE when the caller already has
  # it — the run loop reads it from its plan.
  fleet_item_split_set "$4" || return 70
  fleet_run_category=$fleet_item_category
  fleet_run_name=$fleet_item_name
  if [ "$#" -ge 7 ]; then
    fleet_run_item_state=$7
  else
    fleet_run_item_state=$(fleet_run_state_of "$5")
  fi
  # A category the design holds outright refuses here rather than being
  # advised against. The set is currently empty — `hooks` graduated to the
  # per-item trust gate below — and the predicate stays because "held" is a
  # position a category can be put back into in one line.
  ! fleet_category_held "$fleet_run_category" || return 75
  # POLICY AND DEFINITIONS DISPATCH FIRST, ahead of the state guard below.
  # Their values are not states at all — `policy.cadence_hours: 12`,
  # `policy.canary_group: canary`, a definitions map — so subjecting them to an
  # enabled/disabled check holds every policy item on every host forever, and
  # downstream hosts could never obtain the canary evidence a policy change
  # needs. Policy is read, not installed; a definition is a lookup, not a want.
  case $fleet_run_category in
    policy | definitions.*) return 0 ;;
  esac
  # AN UNRECOGNISED STATE IS HELD, checked ONCE for every remaining category
  # rather than per arm. §4's reader's choice makes a bare scalar the state and a map's
  # `state:` key the state, and every arm below then asks `= enabled`, so a
  # typo (`enable`) or a wrong type (`state: false`) fell into whatever the arm
  # does with "not enabled": packages returned SATISFIED — positive canary
  # evidence that malformed desired state had converged fleet-wide — and
  # plugins silently DISABLED the plugin. Neither is a decision anybody made.
  # A value carrying no state at all still reads `enabled` (§4), so
  # config_files and definitions maps are unaffected.
  #
  # `absent` is the one further state, and only where an uninstall verb exists:
  # a Claude plugin (§3.4's tombstone). Everywhere else it is still held.
  case $fleet_run_item_state in
    enabled | disabled) ;;
    absent) [ "$fleet_run_category" = plugins ] || return 75 ;;
    *) return 75 ;;
  esac
  case $fleet_run_category in
    packages)
      # SATISFIED, and asked BEFORE the resolver: a desired state of `disabled`
      # has no removal verb by design (§10.3 makes removal a separate, capped
      # decision driven by applied/), so there is nothing to do here or on any
      # other host — and that is true whether or not this host has a manager
      # that could have provided the package. Asking the resolver first made an
      # unprovidable disabled package journal `held` and block every downstream
      # host forever on evidence nobody could ever produce.
      [ "$fleet_run_item_state" = enabled ] || return 70
      fleet_run_resolved=$(fleet_run_resolve_package "$3" "$fleet_run_name" "$6") || :
      # One read of the resolution, the five fields the lines below use, each
      # rendered exactly as `jq -r` rendered it alone.
      fleet_run_install_args=$(printf '%s\n' "$fleet_run_resolved" | jq -r '
        [.resolved, .manager, .name, (.attributes.cask // false),
         (if .pin == "flag" then (.version // "") else "" end)] |
        map(if type == "string" then . else tojson end) | join("\u001f")') ||
        fleet_run_install_args=
      IFS=$fleet_run_sep read -r fleet_run_install_ok fleet_run_install_manager \
        fleet_run_install_name fleet_run_install_cask fleet_run_install_version \
        <<EOF
$fleet_run_install_args
EOF
      [ "$fleet_run_install_ok" = true ] || return 75
      # THE VERSION RIDES ALONG. The resolver reports `pin: flag` plus the
      # version and `fleet_package_pinned` then makes the update pass skip the
      # package forever — so dropping the version here meant the store asserted
      # a pin, the installer never received it, and nothing ever revisited it.
      # §5.1.1 calls that exact shape "worse than no pin".
      #
      # An install the run's Homebrew snapshot shows is a no-op — installed and
      # not outdated — is not asked of brew, which would answer "already
      # installed" and exit 0 after a second or more of startup per package.
      fleet_run_brew_current "$fleet_run_install_manager" "$fleet_run_install_name" \
        "$fleet_run_install_cask" "$fleet_run_install_version" ||
        fleet_install_package "$fleet_run_install_manager" "$fleet_run_install_name" \
          "$fleet_run_install_cask" "$fleet_run_install_version"
      ;;
    plugins)
      # A TOMBSTONE converges by uninstalling, and is SATISFIED where the
      # plugin is not installed — asked before the harness check, because a
      # host with no `claude` has no plugin to remove either.
      if [ "$fleet_run_item_state" = absent ]; then
        fleet_run_uninstall_plugin "$3" "$4" "$fleet_run_name" "$5"
        return $?
      fi
      # A definition that does not resolve HOLDS (75). Falling through to the
      # unqualified id here installed from the manager's DEFAULT marketplace —
      # a same-named plugin from a source nobody declared. Empty output with
      # status 0 is the zero-config case below, and only that is unqualified.
      fleet_run_market=$(fleet_run_plugin_market "$3" "$fleet_run_name" "$5") ||
        return 75
      # HELD, not satisfied: a host with no `claude` cannot speak to the item
      # at all, and a peer that has one still must not converge on this host's
      # inability. See the exit-code contract above.
      command -v claude >/dev/null 2>&1 || return 75
      # A NULL MARKETPLACE IS THE ZERO-CONFIG CASE, not a missing one.
      # `fleet_resolve_surface`'s own contract is "a null marketplace means
      # 'wherever this harness looks'", and §5's worked example — `plugins:
      # {ponytail: enabled}` with no marketplace anywhere — is the documented
      # default. Refusing it journaled `held` on every host forever, which in
      # turn made `fleet_hook_trust` report every hook that plugin delivers
      # `enabled_but_untrusted` permanently, because the approval it looks for
      # can only arrive through applied/. Unqualified, and the harness resolves
      # its own default.
      fleet_run_id=$fleet_run_name
      [ -z "$fleet_run_market" ] ||
        fleet_run_id="$fleet_run_name@$fleet_run_market"
      fleet_run_want_enabled=false
      [ "$fleet_run_item_state" = enabled ] && fleet_run_want_enabled=true
      fleet_run_plugin_mutated=false
      fleet_run_resolved_sha=
      if [ -n "$fleet_run_market" ]; then
        # A catalog that cannot prove the bytes — no entry (an unregistered
        # or stale marketplace) or an entry with no SHA — re-registers and
        # refreshes the marketplace, then looks ONCE more (§3.5).
        # ...and a catalog is only accepted from the marketplace's declared
        # source: a same-name repoint holds (fleet_run_marketplace_source_ok).
        fleet_run_marketplace_source_ok "$fleet_run_market" || return $?
        # A repair that failed in a bounded manager call is transient (74); a
        # catalog that still cannot prove the bytes after a repair is
        # standing (75): no entry, or an entry with no SHA.
        fleet_run_catalog=$(fleet_run_plugin_catalog_proven "$fleet_run_id") || {
          fleet_run_marketplace_repair "$fleet_run_market" || return $?
          fleet_run_catalog=$(fleet_run_plugin_catalog_proven "$fleet_run_id") ||
            return 75
        }
        fleet_run_resolved_sha=$(printf '%s\n' "$fleet_run_catalog" |
          jq -r '.source.sha // empty')
        fleet_run_resolved_version=$(printf '%s\n' "$fleet_run_catalog" |
          jq -r '.version // empty')
        fleet_run_installed=$(fleet_run_installed_plugin "$fleet_run_id") || return 75
        fleet_run_installed_sha=$(printf '%s\n' "$fleet_run_installed" |
          jq -r '.gitCommitSha // empty')
        fleet_run_installed_version=$(printf '%s\n' "$fleet_run_installed" |
          jq -r '.version // empty')
        # A marketplace entry without a resolved SHA cannot prove installed
        # bytes. Hold it instead of silently trusting a version string.
        printf '%s\n' "$fleet_run_resolved_sha" |
          grep -Eq '^[0-9a-fA-F]{40}$' || return 75
        # A catalog entry with no version is proven by its SHA alone, as in
        # fleet_run_plugin_identity_matches (lib/apply-claude.sh).
        if [ "$fleet_run_resolved_sha" != "$fleet_run_installed_sha" ] ||
          { [ -n "$fleet_run_resolved_version" ] &&
            [ "$fleet_run_resolved_version" != "$fleet_run_installed_version" ]; }; then
          # install is for the absent-record case; an existing user-scoped
          # record with stale bytes goes through the manager's own update
          # verb (the target-native refresh sequence in
          # fleet-agents/SKILL.md), which installing an already-installed
          # plugin can reject or no-op instead of actually refreshing it.
          if [ -n "$fleet_run_installed_sha" ]; then
            fleet_run_cli_invalidate
            bounded_verb claude plugin update "$fleet_run_id" --scope user >/dev/null 2>&1 || return 74
          else
            fleet_run_cli_invalidate
            bounded_verb claude plugin install "$fleet_run_id" --scope user >/dev/null 2>&1 || return 74
          fi
          # The manager wrote the cache under its caller's umask, and 002
          # leaves it group-writable. Seal it before it is re-verified, its
          # hooks are approved, or roundhouse's own executor check trusts it.
          plugin_cache_seal_permissions "$fleet_run_id" || return 75
          # Trust the manager's exit status for nothing beyond "it ran": a
          # success exit with the catalog identity still unmatched (a no-op
          # install, a race against a catalog refresh) must not journal as
          # applied on stale bytes.
          fleet_run_reverified=$(fleet_run_installed_plugin "$fleet_run_id") || return 74
          [ "$(printf '%s\n' "$fleet_run_reverified" | jq -r '.gitCommitSha // empty')" \
            = "$fleet_run_resolved_sha" ] &&
            { [ -z "$fleet_run_resolved_version" ] ||
              [ "$(printf '%s\n' "$fleet_run_reverified" | jq -r '.version // empty')" \
                = "$fleet_run_resolved_version" ]; } || return 74
          if [ "$fleet_run_want_enabled" = true ]; then
            fleet_run_approve_plugin_hooks "$fleet_run_id" \
              "$fleet_run_resolved_sha" refresh || return $?
          fi
          fleet_run_plugin_mutated=true
        fi
      else
        fleet_run_cli_invalidate
        bounded_verb claude plugin install "$fleet_run_id" --scope user >/dev/null 2>&1 || return 74
        # As above: seal what the manager wrote before approving its hooks.
        plugin_cache_seal_permissions "$fleet_run_id" || return 75
        if [ "$fleet_run_want_enabled" = true ]; then
          fleet_run_approve_plugin_hooks "$fleet_run_id" || return $?
        fi
        fleet_run_plugin_mutated=true
      fi
      # State-verb status is not convergence: read it before attempting the
      # verb. A no-op enable is not an enable operation, and must not turn a
      # locally modified Codex hook into a newly trusted hook on every pass.
      # A fresh install/update has already gone through the identity and hook
      # gates, but some native managers do not expose the state row until the
      # first state verb. In that case the verb result is the transition proof.
      fleet_run_enable_attempted=false
      fleet_run_enable_status=125
      fleet_run_before_enabled=unknown
      [ "$fleet_run_plugin_mutated" = true ] || {
        fleet_run_before_enabled=$(fleet_run_plugin_enabled "$fleet_run_id" true) ||
          return $?
      }
      if [ "$fleet_run_want_enabled" = true ]; then
        if [ "$fleet_run_plugin_mutated" = true ] ||
          [ "$fleet_run_before_enabled" != true ]; then
          fleet_run_enable_attempted=true
          fleet_run_enable_status=0
          fleet_run_cli_invalidate
          bounded_verb claude plugin enable "$fleet_run_id" --scope user >/dev/null 2>&1 ||
            fleet_run_enable_status=$?
        fi
      else
        fleet_run_want_enabled=false
        if [ "$fleet_run_plugin_mutated" = true ] ||
          [ "$fleet_run_before_enabled" != false ]; then
          fleet_run_cli_invalidate
          bounded_verb claude plugin disable "$fleet_run_id" --scope user >/dev/null 2>&1 || :
        fi
      fi
      fleet_run_actual_enabled=$(fleet_run_plugin_enabled "$fleet_run_id") || return $?
      [ "$fleet_run_actual_enabled" = "$fleet_run_want_enabled" ] || return 74
      # Approval follows the verified post-state, not the manager's exit code.
      # Some native managers write enabled state and then return nonzero; the
      # before/after read is the authoritative transition proof. Install/update
      # approval above covers byte changes; a steady-state enable is not a
      # mutation and must not launder a locally modified hook.
      if [ "$fleet_run_want_enabled" = true ] &&
        [ "$fleet_run_enable_attempted" = true ] &&
        [ "$fleet_run_actual_enabled" = true ]; then
        fleet_run_approve_plugin_hooks "$fleet_run_id" \
          "${fleet_run_resolved_sha:-}" || return $?
      fi
      # Steady state (nothing installed, updated or enabled this pass): an
      # approval an earlier pass could not make — Codex had not synced yet —
      # is retried here, or Claude reads converged and the changed hooks stay
      # untrusted for good (fleet_run_codex_hooks_settled).
      if [ "$fleet_run_want_enabled" = true ] && [ "$fleet_run_actual_enabled" = true ] &&
        [ "$fleet_run_plugin_mutated" != true ] && [ "$fleet_run_enable_attempted" != true ]; then
        fleet_run_codex_hooks_settled "$fleet_run_id" "${fleet_run_resolved_sha:-}" || return $?
      fi
      ;;
    skills)
      # Presence only: neither harness carries a skill enable/disable verb
      # (verified against claude 2.1.222 / codex-cli 0.146.0), so state is a
      # reviewed config edit and this path never pretends otherwise. A
      # plugin-qualified name rides its plugin and needs nothing here.
      fleet_run_surface=$(fleet_resolve_surface "$3" skills "$fleet_run_name")
      # `.delivery` and `.source // ""`, each as `jq -r` printed it, in one read.
      fleet_run_surface_fields=$(printf '%s\n' "$fleet_run_surface" | jq -r '
        [.delivery, (.source // "")] | map(if type == "string" then . else tojson end) |
        join("\u001f")') || fleet_run_surface_fields=
      fleet_run_delivery=${fleet_run_surface_fields%%"$fleet_run_sep"*}
      fleet_run_source=${fleet_run_surface_fields#*"$fleet_run_sep"}
      [ "$fleet_run_delivery" = standalone ] || return 0
      fleet_run_install_skill "$fleet_run_name" "$fleet_run_source" "$2"
      ;;
    hooks)
      # §5.1.3's trust gate, and it is the ONLY thing standing between a
      # `hooks:` entry and arbitrary code on every session start.
      #
      # A trusted hook is plugin-delivered and rides its plugin's install
      # (approving the plugin approves its hooks), so there is nothing to do
      # here beyond letting the item journal as applied. A standalone hook is
      # never trusted and, deliberately, HAS NO INSTALL PATH IN THIS FUNCTION
      # AT ALL — not a guarded one. That is what makes "never installable
      # ungated, not even transiently" a property of the code's shape rather
      # than of the order of two lines.
      fleet_hook_trust "$1" "$2" "$3" "$fleet_run_name" >/dev/null || return 75
      return 0
      ;;
    config_files)
      # §6: the run REPORTS the drift and changes nothing. A twice-daily job
      # that silently reverts what someone typed four hours ago is the exact
      # surprise this system exists not to deliver. `config_files` declares
      # OWNERSHIP, not values — the only writer of a managed key is §10.8's
      # rollback, restoring what applied/<host>.yaml records this host wrote.
      #
      # The report reads each MANAGED key's current on-disk value and prints it,
      # changing nothing (convergence.md §6). Full value convergence — the store
      # carrying desired VALUES to enforce against — stays deferred per §5, so
      # there is nothing here to compare to and nothing to stomp; this is the
      # surface that lets a human SEE a hand-edit, not one that reverts it.
      fleet_config_drift "$2" "$fleet_run_name" "$5"
      return 0
      ;;
    runtimes)
      # Exactly one runtime is managed: the host-default Node under the
      # managed npm globals (§5.1.2's amendment). Any other name is a runtime
      # this build has no position on, and is held rather than satisfied.
      [ "$fleet_run_name" = node ] || return 75
      [ "$(fleet_run_state_of "$5")" = enabled ] || return 70
      # 76 (a switch recorded in flight) passes through so the run alerts it
      # as an unverified default, and 73 (a backed-off switch) so the full
      # cadence still retries it; every other failure is a plain hold. The
      # npm pass reads the in-flight record itself.
      fleet_run_node_status=0
      fleet_run_node_converge "$5" "$3" apply || fleet_run_node_status=$?
      case $fleet_run_node_status in
        0 | 73 | 76) return "$fleet_run_node_status" ;;
        *) return 75 ;;
      esac
      ;;
    agents | mcp_servers | projects)
      # The B-3 categories, NAMED rather than caught by a wildcard: no
      # state-alignment verb and no observed state either. They resolve, review
      # and journal; they do not apply.
      return 70
      ;;
    *)
      # AN UNKNOWN CATEGORY IS HELD, never satisfied. §7.7 holds the whole store
      # on a top-level key that is neither a category nor a host fact, and the
      # run never reaches this function for one — but `fleet-apply ITEM` is
      # invoked directly and does. Returning 70 here would journal `satisfied`
      # for state this build cannot interpret, which is positive canary evidence
      # that peers act on. The closed set (§4/fleet_categories) is the point:
      # anything outside it is exactly what nobody has decided about yet.
      return 75
      ;;
  esac
}

# --- §3.4/§3.5 tombstones: `absent` uninstalls through the harness ----------

fleet_run_tombstone_converge() {
  # fleet_run_tombstone_converge STORE HOST DEFS ITEM VALUE DIGEST AT — THE one
  # path a tombstone converges through, for the run and for `fleet-apply`
  # alike: uninstall (fleet_run_uninstall_plugin, through the apply layer),
  # then — when nothing is installed any more, 0 or 70 — forget any applied/
  # record (nothing installed is nothing owned, and a recorded tombstone would
  # read as a prune the day it is compacted away), remember the converged
  # digest host-locally so later passes stay silent, and journal `applied` or
  # `satisfied`. Returns the apply status; a 75 is the caller's to hold.
  tomb_status=0
  fleet_run_apply_item "$1" "$2" "$3" "$4" "$5" '' || tomb_status=$?
  case $tomb_status in
    0 | 70) ;;
    *) return "$tomb_status" ;;
  esac
  # The ownership cleanup must SUCCEED before the post-change state is
  # recorded: a memo and journal entry written over a failed forget would
  # report convergence and silence the retry that the record still needs.
  tomb_owned=$(fleet_applied_digest "$1" "$2" "$4") || {
    printf '  held %s (applied/%s cannot be read to release its ownership)\n' "$4" "$2" >&2
    return 75
  }
  if [ -n "$tomb_owned" ]; then
    fleet_applied_forget "$1" "$2" "$4" || {
      printf '  held %s (its applied/%s record could not be released)\n' "$4" "$2" >&2
      return 75
    }
  fi
  mkdir -p "$(dirname "$(fleet_run_tombstone_memo_path "$4")")"
  printf '%s\n' "$6" >"$(fleet_run_tombstone_memo_path "$4")"
  tomb_outcome=applied
  [ "$tomb_status" -eq 0 ] || tomb_outcome=satisfied
  fleet_journal_append "$1" "$2" \
    "$(jq -cn --arg item "$4" --arg d "$6" --arg at "$7" --arg o "$tomb_outcome" \
      '{item:$item,digest:$d,outcome:$o,at:$at}')" || :
  if [ "$tomb_status" -eq 0 ]; then
    printf '  applied %s (uninstalled)\n' "$4"
  else
    printf '  satisfied %s (absent, and not installed here)\n' "$4"
  fi
  return "$tomb_status"
}

fleet_run_desired() {
  # fleet_run_desired LAYERDIR HOST -> the fold, plus the plugin tombstones its
  # knockout removed: every ITEM this host has an opinion on, with its value.
  # The run reads item values and digests from this, and so do the supervised
  # verbs, so `fleet-review`, `fleet-apply` and the run all see a scalar
  # `absent` tombstone the same way. The plain fold stays what every reader of
  # desired STATE wants — policy, package managers, the alert detections.
  printf '%s\n' "$(fleet_fold "$1" "$2")" \
    "$(fleet_fold_tombstones "$1" "$2" plugins)" | jq -c -s '.[0] * .[1]'
}

fleet_run_tombstone_items() {
  # fleet_run_tombstone_items DESIRED -> every `plugins.<name>` whose desired
  # value is a tombstone: the scalar `absent` or `{state: absent}`.
  printf '%s\n' "$1" | jq -r '
    [(.plugins // {}) | select(type == "object") | to_entries[] |
      select(.value == "absent" or
        ((.value | type) == "object" and .value.state == "absent")) |
      "plugins." + .key] | unique | .[]'
}

# --- §5/§10.4 the alert surface -----------------------------------------------

fleet_run_alerts() {
  # fleet_run_alerts STORE HOST FOLD LAYERDIR LEDGER — every detection predicate lane
  # A landed, wired to the one writer. Each of these is a condition that would
  # otherwise converge something this reader does not understand.
  #
  # AND EACH ONE IS A HOLD, not only an alert. §7.7 rows 3 and 4 specify a hold
  # and these predicates' own comments claim one ("the run holds EVERYTHING and
  # alerts naming it. Never silent"), but nothing read their output — every call
  # was suffixed `|| :` and the run converged anyway. So this function now
  # PRINTS the holds it detected and the caller acts on them: `!hold <reason>`
  # for the two §7.7 store-wide rows, `<item> <reason>` for a collision, which
  # is a refusal of that config file's widening and not of the store.
  #
  # Every kind here is a CONDITION alert (fleet_alert_lifecycle_rows): the
  # store-wide checks set or clear theirs (fleet_alert_set), and the per-file
  # collisions are checked and raised into the pass's LEDGER for the
  # end-of-pass sweep (fleet_alert_sweep).
  fleet_run_unknown=$(fleet_unknown_categories "$3" | tr '\n' ' ')
  fleet_run_alert_on=false
  [ -z "${fleet_run_unknown% }" ] || fleet_run_alert_on=true
  fleet_alert_set "$1" "$2" unknown-category unknown-category "$fleet_run_alert_on" \
    "top-level keys that are neither a category nor a host fact: ${fleet_run_unknown% }" ||
    :
  [ -z "${fleet_run_unknown% }" ] ||
    printf '!hold %s\n' \
      "top-level keys that are neither a category nor a host fact: ${fleet_run_unknown% }"
  # The real tree, not the exported layers: an unrecognised directory is one
  # nothing folded, so a dir-filtered export can never see it.
  fleet_run_unknown=$(fleet_unknown_layer_dirs "$1" | tr '\n' ' ')
  fleet_run_alert_on=false
  [ -z "${fleet_run_unknown% }" ] || fleet_run_alert_on=true
  fleet_alert_set "$1" "$2" unknown-store-dir unknown-store-dir "$fleet_run_alert_on" \
    "unrecognised store directories: ${fleet_run_unknown% }" || :
  [ -z "${fleet_run_unknown% }" ] ||
    printf '!hold %s\n' "unrecognised store directories: ${fleet_run_unknown% }"
  # Both collision checks scan the whole fold: every config file is CHECKED.
  fleet_alert_checked "$5" config-key-collision '*'
  fleet_alert_checked "$5" chezmoi-coownership '*'
  fleet_config_key_collisions "$3" |
    while IFS=$(printf '\t') read -r fleet_run_file fleet_run_key; do
      [ -n "$fleet_run_file" ] || continue
      fleet_alert_raise "$5" "$1" "$2" config-key-collision \
        config-key-collision \
        "$fleet_run_file: managed key $fleet_run_key collides with a never namespace" \
        "config_files.$fleet_run_file" || :
      printf 'config_files.%s managed key %s collides with a never namespace\n' \
        "$fleet_run_file" "$fleet_run_key"
    done
  fleet_config_coowned "$3" |
    while IFS=$(printf '\t') read -r fleet_run_file fleet_run_key; do
      [ -n "$fleet_run_file" ] || continue
      fleet_alert_raise "$5" "$1" "$2" chezmoi-coownership \
        chezmoi-coownership \
        "$fleet_run_file: managed key $fleet_run_key is also written by chezmoi" \
        "config_files.$fleet_run_file" || :
    done
}

# --- §6 step 6 and §6.1(b): publication and the nudge -------------------------

fleet_run_publish() {
  # fleet_run_publish STORE HOST SESSION INTENT ITEMS [SUBJECT] — describe, move
  # the bookmark, push, and land @ on the published commit. SUBJECT defaults to
  # the run's own `converge on HOST`; a supervised verb names what it did.
  #
  # NEVER a bare `jj new -m ''` here. `jj git push` leaves an empty UNDESCRIBED
  # working-copy commit of its own; naming the target is what makes @ a child
  # of the bookmark instead of a child of that leftover, and it is the line
  # that keeps §8.1's invariant true between runs.
  #
  # A bookmark move that jj REFUSES is a failed publish, never a silent one: jj
  # will not move main sideways or backwards (an @ that descends from a stale
  # local head, not from main), and pushing the unmoved main afterwards pushes
  # nothing while the caller reports success and the work sits in an orphan.
  # No --allow-backwards: a move that would drop main's own commits is exactly
  # what must not happen quietly.
  if [ "$(jj -R "$1" log -r @ --no-graph -T 'if(empty,"y","n")')" = n ]; then
    jj -R "$1" describe -r @ -m "${6:-converge on $2}

$(fleet_vcs_trailers "$2" "$3" "$4" "$5")" >/dev/null
    jj -R "$1" bookmark set main \
      -r "$(jj -R "$1" log -r @ --no-graph -T 'commit_id')" >/dev/null || {
      printf 'roundhouse: could not move main to the new commit (it does not descend from main); nothing published\n' >&2
      return 65
    }
  fi
  fleet_run_target=$(fleet_vcs_heads_local "$1" | head -1)
  [ -n "$fleet_run_target" ] || return 65
  fleet_vcs_publish "$1" "$fleet_run_target"
}

fleet_run_nudge() {
  # fleet_run_nudge STORE HOST LAYERDIR INTERVAL — §6.1(b). Outbound only, no
  # listener, no daemon, no inbound port. It carries NO DATA: the nudge says
  # "go look", and the peer then runs its ordinary fast path with full gates,
  # so a nudge from a compromised host can cause exactly one thing — an early
  # fetch of content that is signature-gated anyway.
  #
  # GENUINELY DELETABLE, and that is the test an accelerator has to pass:
  # remove this loop and the system still converges at poll speed. Nothing
  # depends on it, and a policy `push_nudge: false` or a missing peer degrades
  # to the poll floor without an error, a retry queue or a record.
  #
  # The ten-second bound is on the REMOTE COMMAND, not just the connect:
  # ConnectTimeout alone leaves a peer that connects and then hangs holding the
  # pushing host's wait indefinitely. It is a watchdog rather than `timeout(1)`
  # because ssh_run is a shell function — and because macOS ships no `timeout`,
  # so depending on one would silently delete the accelerator on half the
  # fleet.
  fleet_run_memo=$(fleet_run_state_dir)/nudge-unreachable
  # Remembered for ONE interval only, so a peer that comes back is retried.
  fleet_run_skip=$fleet_run_memo
  if [ ! -f "$fleet_run_memo" ] ||
    [ "$(($(date +%s) - $(fleet_run_mtime "$fleet_run_memo")))" -gt "$4" ]; then
    fleet_run_skip=/dev/null
  fi
  mkdir -p "$(dirname "$fleet_run_memo")"
  : >"$fleet_run_memo.next"
  for fleet_run_peer in $(fleet_ssh_render_hosts "$3"); do
    [ "$fleet_run_peer" != "$2" ] || continue
    ! grep -Fqx "$fleet_run_peer" "$fleet_run_skip" 2>/dev/null || continue
    fleet_run_nudge_peer "$fleet_run_peer" ||
      printf '%s\n' "$fleet_run_peer" >>"$fleet_run_memo.next"
  done
  mv -f "$fleet_run_memo.next" "$fleet_run_memo"
}

fleet_run_nudge_peer() {
  # One bounded, best-effort nudge. It CARRIES NO DATA: "go look", nothing
  # more. The peer then runs its ordinary fast path — fetch from the hub, full
  # review gates, canary, the lot — so a nudge from a compromised host can
  # cause exactly one thing: an early fetch of content that is signature-gated
  # anyway.
  #
  # §6.1: the nudge is the peer's ordinary TRIGGER, not its pass. Running the
  # whole `fleet-run --fast` inside this channel tied the peer's pass to a
  # ten-second SSH watchdog that killed it mid-apply; `fleet-trigger` stamps,
  # starts the peer's own scheduled job (or a detached pass) and returns, so
  # the pass runs under the peer's scheduler and this host waits for the
  # handshake only.
  ssh_run "rh-$1" 'roundhouse fleet-trigger --fast' </dev/null >/dev/null 2>&1 &
  fleet_run_nudge_pid=$!
  (
    sleep 10
    kill -TERM "$fleet_run_nudge_pid" 2>/dev/null || :
  ) >/dev/null 2>&1 &
  fleet_run_nudge_watch=$!
  fleet_run_nudge_status=0
  wait "$fleet_run_nudge_pid" || fleet_run_nudge_status=$?
  kill -TERM "$fleet_run_nudge_watch" 2>/dev/null || :
  wait "$fleet_run_nudge_watch" 2>/dev/null || :
  [ "$fleet_run_nudge_status" -eq 0 ]
}

fleet_run_mtime() {
  # stat -c first: on Linux `stat -f` is filesystem stat and dumps a report to
  # stdout, so the -f-first form leaks that into the value; on macOS `stat -c`
  # is an illegal option and cleanly falls through to `stat -f`.
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || printf '0\n'
}

# --- §6.3 the run lock, as the run takes it ---------------------------------

fleet_run_lock_take() {
  # fleet_run_lock_take STORE HOST LOCK — fleet_lock_take with this store's
  # stale threshold (two full cadences, fleet_run_stale_after), and the alert a
  # takeover owes: evidence, not a refusal, so the run proceeds. Exit 0
  # acquired (by takeover or not), 10 held by a live run, 75 refused.
  fleet_run_lock_take_rc=0
  fleet_lock_take "$3" "$(fleet_run_stale_after "$1" "$2")" "$(fleet_run_pass_ceiling)" ||
    fleet_run_lock_take_rc=$?
  case $fleet_run_lock_take_rc in
    11)
      fleet_alert_write "$1" "$2" lock-takeover lock-takeover \
        "took over the run lock from a dead holder ($fleet_lock_taken_from); the run it belonged to did not finish" ||
        :
      ;;
    12)
      fleet_alert_write "$1" "$2" lock-takeover lock-takeover \
        "stopped a run that held the run lock past the $(fleet_run_pass_ceiling)s ceiling ($fleet_lock_taken_from) and took the lock over; that run did not finish" ||
        :
      ;;
    *) return "$fleet_run_lock_take_rc" ;;
  esac
}

fleet_run_pass_ceiling() {
  # The longest a pass may hold the run lock before the next run stops it as
  # hung (fleet_lock_take's ceiling): two hours. A converged full pass takes a
  # few minutes; genuine package downloads are what the margin is for, so a
  # pass that is still running at the ceiling is stuck, not busy. The test
  # hook only shortens it, and only under the self-check.
  if fleet_test_hook "${ROUNDHOUSE_TEST_PASS_CEILING:-}"; then
    printf '%s\n' "$ROUNDHOUSE_TEST_PASS_CEILING"
    return
  fi
  printf '7200\n'
}

# --- the commands -------------------------------------------------------------

fleet_run_command() {
  # `roundhouse fleet-run [--fast|--full]` — §6.1's two cadences. Fast is the
  # propagation path; full is maintenance. Splitting them is what lets the
  # propagation interval be short without running discovery, doctoring and
  # upstream fetches 72 times a day.
  #
  # NOT a subshell, deliberately, and it always ends in `exit`: the scheduler
  # signals the process it started, so the run's signal traps must be in that
  # process. In a `( … )` child the CLI process died on SIGTERM while the run
  # went on without anyone able to stop it.
  fleet_run_env
  require_jq
  require_yq
  run_mode=fast
  while [ $# -gt 0 ]; do
    case $1 in
      --fast) run_mode=fast ;;
      --full) run_mode=full ;;
      *)
        printf 'roundhouse: unknown fleet-run option: %s\n' "$1" >&2
        exit 64
        ;;
    esac
    shift
  done

  run_store=$(fleet_store_path)
  run_host=$(fleet_host_name)
  fleet_vcs_store_ready "$run_store" || exit $?

  # §10.6: one run per host. The stale threshold keys on the FULL cadence and
  # never on the fast interval — a 40-minute threshold would declare a live
  # run's lock stale on the very next fast run.
  run_lock=$(fleet_lock_path)
  run_lock_status=0
  fleet_run_lock_take "$run_store" "$run_host" "$run_lock" || run_lock_status=$?
  case $run_lock_status in
    0) ;;
    10)
      printf 'roundhouse: another run holds %s; exiting without acting\n' \
        "$run_lock" >&2
      exit 0
      ;;
    *) exit "$run_lock_status" ;;
  esac
  # Release by NONCE, never by path: a run that was judged dead and taken over
  # must not delete its live successor's lock when it finally exits.
  run_lock_nonce=$fleet_lock_nonce_held
  run_lock_held=true
  run_tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-fleet-run.XXXXXX")
  # A signal ENDS the run: its trap exits 128+N, which runs the EXIT trap —
  # the lock is released and nothing after it runs. A handler that only
  # cleaned up and returned let the loop go on to another pass with no lock.
  # (Each pass closes its own apply batch on its way out, fleet_run_pass.)
  trap '[ "$run_lock_held" != true ] || fleet_lock_release "$run_lock" "$run_lock_nonce" || :
    rm -rf "$run_tmp"' EXIT
  fleet_lock_signals_exit
  # §8.6: the abort button for a bad local apply, captured ONCE per run,
  # before its first pass and deliberately WITHOUT --ignore-working-copy (that
  # flag suppresses the colocated auto-import, so restoring to the newest
  # operation exports an empty view and deletes the bookmarks outright). One
  # run is one abort point however many in-process passes it makes: restoring
  # it undoes them all, which is what an operator aborting "this run" means.
  run_op=$(fleet_vcs_op_id "$run_store")
  mkdir -p "$(fleet_run_state_dir)"
  printf '%s\n' "$run_op" >"$(fleet_run_state_dir)/starting-operation"

  # §6.1: the pass, and its in-process re-runs while triggers land mid-pass.
  # Called plainly: each pass keeps errexit live (fleet_trigger_converge), and
  # the worst pass status comes back in fleet_trigger_status.
  #
  # THE HANDOFF. A trigger can move the stamp after the loop's last
  # comparison but before the lock is released: its own run found the lock
  # and exited, and a scheduler `start` of the job that is still running
  # queues nothing. So once the lock is released the stamp is compared again,
  # and a move takes the lock back IN THIS PROCESS (non-blocking) and
  # converges again — never a detached pass, which launchd and systemd would
  # kill with this job's process group the moment it ends. If another run
  # holds the lock by then, it is the one that will see the stamp. Two
  # handoffs at most; a storm past that waits for the next scheduled run.
  # A move AFTER this last compare is the trigger's to catch: while this job
  # runs with no lock held, it starts the job only once the job has exited
  # (fleet_trigger_exit_pending).
  run_status=0
  run_round=0
  while :; do
    fleet_trigger_converge fleet_run_pass "$run_tmp/round-$run_round" "$run_mode" \
      "$run_lock" "$run_lock_nonce"
    [ "$fleet_trigger_status" -le "$run_status" ] || run_status=$fleet_trigger_status
    [ "$fleet_trigger_status" -lt 128 ] || exit "$fleet_trigger_status"
    fleet_lock_release "$run_lock" "$run_lock_nonce" || break
    run_lock_held=false
    [ "$(fleet_trigger_stamp_state)" != "$fleet_trigger_last_stamp" ] || break
    [ "$run_round" -lt 2 ] || {
      printf 'roundhouse: triggers kept arriving as the run released its lock; the next scheduled run picks them up\n'
      break
    }
    run_lock_status=0
    fleet_run_lock_take "$run_store" "$run_host" "$run_lock" || run_lock_status=$?
    case $run_lock_status in
      0) ;;
      10)
        printf 'roundhouse: a trigger arrived as this run released its lock; the run that holds it now sees it\n'
        break
        ;;
      *)
        printf 'roundhouse: a trigger arrived as this run released its lock, and the lock could not be taken again (%s); the next run picks it up\n' \
          "$run_lock_status" >&2
        break
        ;;
    esac
    run_lock_nonce=$fleet_lock_nonce_held
    run_lock_held=true
    run_round=$((run_round + 1))
    run_mode=fast
    printf 'roundhouse: a trigger arrived as this run released its lock; took it again and converging in-process\n'
  done
  exit "$run_status"
}

fleet_run_pass() {
  # fleet_run_pass PASS-TMP MODE — one observe/converge pass, under
  # fleet_run_command's lock, run by fleet_trigger_converge. Its arguments are
  # PER PASS: a fresh scratch directory holding this pass's alert ledger (the
  # one the end-of-pass sweep reads), and the cadence (fast on a re-run). PER
  # RUN, from the caller: run_store, run_host, run_lock and its nonce, run_op.
  # Everything else — the marketplace repair memo (reset below) and all this
  # body computes — is the pass's own. A subshell, so every `exit` below ends
  # THIS pass and hands its status back to the loop.
  errexit_require fleet_run_pass
  run_tmp=$1
  run_mode=$2
  run_ledger="$run_tmp/alert-ledger"
  # ANY way out of this pass — a refusal, an errexit, a signal — first lands
  # whatever the apply loop has queued (fleet_run_batch_open): an item it
  # already installed is recorded as owned, as the per-item writes recorded
  # it. HERE, in the pass's own subshell, because the batch is: a trap in
  # fleet_run_command never saw it open. A signal exits 128+N, which runs it.
  trap '[ -z "${fleet_run_batch:-}" ] || fleet_run_batch_close "$run_store" "$run_host" || :' EXIT
  fleet_lock_signals_exit
  # Captured BEFORE any fetch: what arrives is what §7.7 has to gate, and after
  # the fetch there is no other way to tell new from known. (The poll floor's
  # own fetch lands in a private ref and does not move main@origin.)
  run_pre_origin=$(fleet_vcs_head_origin "$run_store")

  # §6.1: this host's own scheduled jobs. A disabled or missing job is ALERTED,
  # never re-enabled — only `fleet-schedule install`, run by a human, enables.
  # Before the floor, so the alert it writes is published by this very pass.
  fleet_schedule_check "$run_store" "$run_host" || :

  # §6.1(a)/§6.4. One incremental fetch, a tree-id compare, exit — no fold, no
  # reconcile, no commit, no push. The convergence pass runs only when desired
  # state moved or a local condition says there is work.
  if [ "$run_mode" = fast ] && fleet_run_poll_floor "$run_store"; then
    fleet_heartbeat_local "$(fleet_now)" || :
    printf 'roundhouse: desired state unchanged (%s); nothing to push, clean working copy — one incremental fetch, no convergence pass (§6.4)\n' \
      "$fleet_run_floor_note"
    printf 'roundhouse: starting operation %s\n' "$run_op"
    exit 0
  fi
  run_fetched=true
  fleet_vcs_fetch "$run_store" origin 2>/dev/null || run_fetched=false
  [ "$run_fetched" = true ] ||
    printf 'roundhouse: could not reach the store remote; converging from last known (§10.3, never prune)\n' >&2

  # §7.11.2: a re-root and the §7.12.3 rollback attack are byte-for-byte
  # indistinguishable EXCEPT BY THE ARCHIVE, so the archive protocol runs
  # before anything adopts the fetched head. Its failure branch IS the rollback
  # protection: an attacker who re-roots without publishing an archive
  # containing this host's reviewed-ref cannot get it to adopt.
  run_fetched_head=$(fleet_vcs_head_origin "$run_store")
  if [ -n "$run_fetched_head" ]; then
    if run_catchup=$(fleet_trust_catch_up "$run_store" "$run_fetched_head") &&
      [ -z "$run_catchup" ]; then
      fleet_alert_set "$run_store" "$run_host" rollback rollback false ''
    else
      fleet_alert_set "$run_store" "$run_host" rollback rollback true \
        "refusing the fetched head: $(printf '%s' "${run_catchup:-reviewed-ref is not an ancestor of the fetched head}" | head -c 300)" ||
        :
      printf 'roundhouse: %s; holding everything and alerting (§7.11.2/§7.12.3)\n' \
        "${run_catchup:-the fetched head is not a descendant of reviewed-ref}" >&2
      exit 65
    fi
  fi

  # §8.1's invariant, repaired before anything reads the graph: the bootstrap
  # leaves an empty undescribed commit under @ that would otherwise become a
  # permanent ancestor of main and refuse every future push.
  fleet_run_prune_empty "$run_store"

  # --- step 0: is this the second half of an earlier reconcile? (§8.1) ---
  run_state=clean
  run_workbench=$(fleet_vcs_resolution_workbench "$run_store")
  if [ -n "$run_workbench" ]; then
    # A human may have resolved it since; if not, the fold refuses and the
    # items stay held. Readable from repo state alone, because $M, $WC and
    # $LOCAL do not survive between runs.
    run_state=conflicted
    run_reference=$run_workbench
    if run_folded=$(fleet_vcs_fold_resolution "$run_store" 2>/dev/null); then
      run_state=clean
      run_reference=$run_folded
    fi
  else
    # §6 step 4 and its §8.2 precedence: the gate runs only off the conflicted
    # path, and a failure refuses to PROMOTE rather than refusing to converge.
    run_broken=$(fleet_run_promote_gate "$run_store") || run_broken=${run_broken:-x}
    if [ -n "${run_broken:-}" ]; then
      fleet_alert_set "$run_store" "$run_host" layer-parse layer-parse true \
        "refusing to promote; converging from the last good main: $(printf '%s' "$run_broken" | head -c 300)" ||
        :
      run_reference=$(fleet_vcs_head_origin "$run_store")
      [ -n "$run_reference" ] || run_reference=$(fleet_vcs_heads_local "$run_store" | head -1)
      [ "$(fleet_vcs_heads_local "$run_store" | grep -c .)" -le 1 ] || {
        printf 'roundhouse: a layer file does not parse and main is diverged; holding everything\n' >&2
        exit 65
      }
    else
      fleet_alert_set "$run_store" "$run_host" layer-parse layer-parse false ''
      run_out=$(fleet_vcs_reconcile "$run_store" "$run_host" "scheduled/agent" \
        "$run_mode convergence") || exit $?
      run_state=${run_out%% *}
      run_reference=${run_out#* }
    fi
  fi

  # --- §8.3: the hold set, from per-head folds over real commits ---
  # THE HEADS ARE THE BOOKMARK HEADS, recomputed — never parents($M), which is
  # the heads PLUS the operator's in-flight edit.
  if [ "$run_state" = conflicted ]; then
    run_heads=$( (fleet_vcs_heads_local "$run_store"
      fleet_vcs_head_origin "$run_store") | grep . | LC_ALL=C sort -u)
  else
    run_heads=$run_reference
  fi
  run_head_count=$(printf '%s\n' "$run_heads" | grep -c .)
  run_index=0
  : >"$run_tmp/values"
  for run_head in $run_heads; do
    run_index=$((run_index + 1))
    fleet_run_export "$run_store" "$run_head" "$run_tmp/head-$run_index"
    # The item universe is the DESIRED document (fleet_run_desired), so §3.4's
    # tombstones join it with their own digest. The fold knocks `absent` out,
    # and from it alone a tombstoned plugin read as "gone from the layers" — a
    # capped prune that forgot the record and uninstalled nothing — and a host
    # that never owned it never heard of it at all.
    fleet_run_item_digests \
      "$(fleet_run_desired "$run_tmp/head-$run_index" "$run_host")" \
      "$run_tmp/head-$run_index" >>"$run_tmp/values"
  done
  # The reviewed tree R. On the clean path that is the merge, and there is one
  # head. On the conflicted path it is the first head — legitimate because
  # §8.3 only converges items whose value is IDENTICAL at every head, so any
  # head answers for them, and the rest are held.
  run_layers=$run_tmp/head-1
  # Two readings of R, merged ONCE: `run_desired` for item values (tombstones
  # included), `run_fold` for desired state — policy, package managers and the
  # detections — which a tombstone is not.
  run_fold=$(fleet_fold "$run_layers" "$run_host")
  run_desired=$(fleet_run_desired "$run_layers" "$run_host")
  run_defs=$(fleet_definitions_load "$run_layers")
  fleet_vcs_enrolled_hosts "$run_store" "$run_reference" >"$run_tmp/hosts"
  grep -Fqx "$run_host" "$run_tmp/hosts" || printf '%s\n' "$run_host" >>"$run_tmp/hosts"

  fleet_vcs_hold_set "$run_head_count" <"$run_tmp/values" >"$run_tmp/verdicts"

  # §7.7: an unverifiable commit holds exactly the items resolved from the
  # files it touched. Everything else converges.
  # What ARRIVED, which is what §7.7 has to gate: the pre-fetch origin head is
  # the only stateless way to tell new from known, and on a never-fetched store
  # the whole (tiny) history is new by definition.
  run_range="::$run_reference"
  [ -z "$run_pre_origin" ] || run_range="$run_pre_origin..$run_reference"
  # Rule 4's roster — this host's CURRENT reviewed head, which is what makes
  # removals bite backward. Rules 3 and 4 are the two-sided check: 3 alone lets
  # a removed host keep pushing forever, 4 alone would reject a legitimate
  # newcomer except that the ancestry property means it cannot.
  fleet_trust_roster_at_head "$run_store" "$run_reference" "$run_tmp/reviewed-roster"
  fleet_run_signature_holds "$run_store" "$run_range" "$run_tmp/hosts" \
    "$run_layers" "$run_host" "$run_tmp/reviewed-roster" "$run_tmp/rosters" \
    >"$run_tmp/sigholds" 2>/dev/null || :

  # `!hold` is the marker for a refusal whose scope is the WHOLE run rather
  # than an item: a rejected `trust/signers.yaml` commit (whose consequences
  # are otherwise scoped to layer files it did not touch) and an unusable
  # revocation list. Both are conditions under which nothing in the range can
  # be trusted, so they take the same branch materialization drift takes.
  run_full_hold=$(awk '$1 == "!hold" { $1 = ""; sub(/^ /, ""); print; exit }' \
    "$run_tmp/sigholds")
  # The store-wide hold has a kind of its own; this clears the key older
  # passes and fleet-compact-alerts gave it under the per-item `integrity`
  # kind, which nothing else would ever clear or age.
  fleet_alert_clear "$run_store" "$run_host" integrity integrity-store-wide
  if [ -n "$run_full_hold" ]; then
    fleet_alert_set "$run_store" "$run_host" integrity-store-wide integrity-store-wide true \
      "$(printf '%s' "$run_full_hold" | head -c 300)" || :
    printf 'roundhouse: %s; holding everything (§7.7/§7.12.5)\n' "$run_full_hold" >&2
    exit 65
  fi
  fleet_alert_set "$run_store" "$run_host" integrity-store-wide integrity-store-wide false ''

  # §7.9: install the roster the ratchet derived, and compare what is already
  # installed against it. The compare is nearly free and fails in a DIFFERENT
  # direction from ownership — it catches an attacker who does get root. A
  # mismatch is a loud alert and a full hold, never a repair.
  #
  # SKIPPED ON THE CONFLICTED PATH, and not as tidiness: `run_reference` is the
  # conflicted merge there, so `trust/signers.yaml` read at it comes back with
  # snapshot markers, parses to nothing, and renders as "nobody is trusted" —
  # which would read as total roster drift and hold the whole store on the one
  # path §8.2b exists to resolve. There is no single reviewed ref during a
  # divergence, so there is nothing to compare against yet.
  if [ "$run_state" = clean ]; then
    run_drift=$(fleet_trust_materialization_drift "$run_store")
    # A REFUSED MATERIALIZATION IS A HOLD, not a swallowed `|| :`. §7.12.3's
    # generation-rollback and non-descendant-of-reviewed-ref refusals (and a
    # privileged helper that refuses) all come back non-zero here, and every
    # sibling hold in this function exits 65 and alerts — this one silently
    # converged on. Take the same branch the drift compare below takes.
    #
    # A REVIEWED-REF OFF THE PUBLISHED LINE (exit 66) GETS ITS OWN KEYED ALERT,
    # naming the mark and its newest published ancestor and pointing at the
    # doctor row for the re-point command; the short hold text is sized under
    # §10.4's cap by construction, so the alert cannot be refused and leave the
    # hold silent. Every other refusal keeps the generic key. (A holding host
    # publishes nothing, so peers learn of it from the stale-host alert, #42.)
    run_mat_rc=0
    fleet_trust_materialize "$run_store" "$run_reference" || run_mat_rc=$?
    if [ "$run_mat_rc" -ne 0 ]; then
      run_reference_short=${run_reference:0:12}
      if [ "$run_mat_rc" -eq 66 ]; then
        read -r run_rstate run_rref run_ranchor <<EOF
$(fleet_trust_reviewed_state "$run_store")
EOF
        fleet_alert_set "$run_store" "$run_host" materialization \
          materialization-refused false ''
        fleet_alert_set "$run_store" "$run_host" materialization \
          reviewed-ref-unpublished true \
          "$(fleet_trust_reviewed_hold_text "$run_store" "$run_rref" \
            "${run_ranchor:--}" short)" || :
      else
        fleet_alert_set "$run_store" "$run_host" materialization \
          reviewed-ref-unpublished false ''
        fleet_alert_set "$run_store" "$run_host" materialization \
          materialization-refused true \
          "materialization refused for commit[$run_reference_short] (abbreviated commit id): a roster generation rollback or a non-descendant head (§7.12.3); holding everything" ||
          :
      fi
      printf 'roundhouse: materialization refused (§7.12.3); holding everything (§7.9)\n' >&2
      exit 65
    fi
    fleet_trust_privileged >/dev/null 2>&1 ||
      printf 'roundhouse: no privileged materialization lane; the roster is same-user writable, which buys no persistence protection past revocation (§7.9)\n' >&2
    [ -z "$run_drift" ] || {
      fleet_alert_set "$run_store" "$run_host" materialization materialization true \
        "$(printf '%s' "$run_drift" | head -c 300)" || :
      printf 'roundhouse: %s; holding everything (§7.9)\n' "$run_drift" >&2
      exit 65
    }
    fleet_alert_set "$run_store" "$run_host" materialization materialization-refused false ''
    fleet_alert_set "$run_store" "$run_host" materialization reviewed-ref-unpublished false ''
    fleet_alert_set "$run_store" "$run_host" materialization materialization false ''
  fi

  fleet_run_alerts "$run_store" "$run_host" "$run_fold" "$run_layers" \
    "$run_ledger" >"$run_tmp/detections"
  run_full_hold=$(awk '$1 == "!hold" { $1 = ""; sub(/^ /, ""); print; exit }' \
    "$run_tmp/detections")
  if [ -n "$run_full_hold" ]; then
    printf 'roundhouse: %s; holding everything (§4/§7.7)\n' "$run_full_hold" >&2
    exit 65
  fi
  # The item-scoped detections join the same hold file the signature gate
  # writes, so the apply loop below reads one surface and not two.
  grep -v '^!hold ' "$run_tmp/detections" >>"$run_tmp/sigholds" || :
  fleet_run_definition_hold_consumers "$run_tmp/sigholds" \
    "$run_tmp/verdicts" "$run_tmp/values" "$run_tmp" \
    || exit 65
  fleet_run_hold_items_into_verdicts "$run_tmp/sigholds" \
    "$run_tmp/verdicts" "$run_tmp"

  # §5's rendered aliases, and the include line that makes them reachable. The
  # destination directory is this run's to create: the render is pure and
  # writes through safe_output, which refuses a destination whose directory
  # does not exist.
  mkdir -p "$HOME/.ssh/config.d"
  chmod 700 "$HOME/.ssh" 2>/dev/null || :
  run_ssh_failed=false
  if fleet_ssh_config_render "$run_layers" "$HOME/.ssh/config.d/roundhouse" \
    2>/dev/null; then
    fleet_run_ssh_include || :
  else
    run_ssh_failed=true
  fi
  fleet_alert_set "$run_store" "$run_host" ssh-render ssh-render "$run_ssh_failed" \
    'a host field failed validation; no ssh config was rendered (§5)' || :

  # --- §8.2b: the run's own agent resolves, in the same run ---
  run_resolved_items=
  if [ "$run_state" = conflicted ]; then
    fleet_run_resolve_conflict "$run_store" "$run_host" "$run_tmp" \
      "$run_fold" "$run_heads" || :
    if [ -f "$run_tmp/resolved" ]; then
      run_resolved_items=$(tr '\n' ' ' <"$run_tmp/resolved")
      run_folded=$(fleet_vcs_fold_resolution "$run_store" \
        "resolve $run_resolved_items on $run_host

$(fleet_vcs_trailers "$run_host" scheduled/agent \
          'agent resolution, §8.2b' "$run_resolved_items")") && {
        run_state=clean
        run_reference=$run_folded
        # Only now is the resolution real; peers may not read `outcome:
        # resolved` for an item whose fold refused.
        fleet_run_resolution_journal "$run_store" "$run_host" "$run_tmp"
      } || :
    fi
  fi

  # --- §6 step 6: review -> verdict -> apply -> applied/ -> journal ---
  # PER PASS, not per process: one marketplace repair per marketplace per pass
  # (fleet_run_marketplace_repair), forgotten here so a later pass in the same
  # process retries a repair an earlier pass could not make.
  fleet_run_marketplace_repair_reset
  run_canary_group=$(fleet_policy_get "$run_fold" canary_group)
  run_wait=$(fleet_policy_get "$run_fold" canary_wait_hours)
  fleet_run_canary_hosts "$run_layers" "$run_canary_group" "$run_tmp/hosts" \
    >"$run_tmp/canaries"
  run_self_canary=false
  ! grep -Fqx "$run_host" "$run_tmp/canaries" || run_self_canary=true
  run_now=$(fleet_now)
  run_applied_items=
  # Any `applied` or `satisfied` record this pass — the evidence §10.1 reads,
  # and the one thing that always publishes a heartbeat with it (§6.3).
  run_applied_any=false
  # Set when an item waits on canary evidence; the poll floor will not exit
  # while one does, because that evidence arrives as records (§6.4).
  run_canary_waiting=false
  # Set by a runtime or transient hold (an apply that failed, an identity that
  # could not be read): retried next pass even if the remote never moves.
  run_retry_owed=false

  # §10.3's removal set, capped BEFORE any removal applies: ONE tagged list,
  # `prune ITEM` (owned, gone from the layers) and `uninstall ITEM` (a
  # tombstone with something installed here), and one over-cap rule
  # (fleet_run_removals_over). Over the cap a tag's ENTIRE set holds — neither
  # term catches a one-line deletion, and nothing should: that is a legitimate
  # edit, and its defence is apply-time review naming the item.
  : >"$run_tmp/removals"
  # One pass over the owned items, asking each the same two questions:
  #  - An item held by §8.3 is not gone; the heads merely disagree about
  #    whether it exists. Pruning it would uninstall software on the strength
  #    of an open conflict. (The `grep -Fqx "held <item>"` the loop used.)
  #  - Presence is asked of the ITEM UNIVERSE this run computed, not of the
  #    fold alone: `definitions.*` items are real items with digests and
  #    verdicts (§5.1) and they are deliberately outside the fold, so asking
  #    the fold would read every one of them as "gone from the layers" and
  #    prune it with a false `outcome: reverted` record. (`$1 == item` over
  #    the values.)
  fleet_record_read "$(fleet_applied_path "$run_store" "$run_host")" '{}' |
    jq -r '(.items // {}) | keys[]' |
    LC_ALL=C awk '
      FILENAME == ARGV[1] { held[$0] = 1; next }
      FILENAME == ARGV[2] { present[$1] = 1; next }
      $0 != "" && !(("held " $0) in held) && !($0 in present) { print "prune " $0 }
    ' "$run_tmp/verdicts" "$run_tmp/values" - >"$run_tmp/removals"
  # A tombstone that would UNINSTALL something here is a genuine removal and
  # joins the list; one that finds nothing installed changes nothing and does
  # not. Undecidable (fleet_run_tombstone_target's 75) joins it, because the
  # cap is the direction to be wrong in.
  fleet_run_tombstone_items "$run_desired" >"$run_tmp/tombstones"
  while IFS= read -r run_tomb_item; do
    [ -n "$run_tomb_item" ] || continue
    ! grep -Fqx "held $run_tomb_item" "$run_tmp/verdicts" || continue
    run_tomb_value=$(fleet_item_value "$run_desired" "$run_tomb_item")
    run_tomb_target=$(fleet_run_tombstone_target "$run_defs" \
      "${run_tomb_item#plugins.}" "$run_tomb_value") || run_tomb_target=undecidable
    [ -z "$run_tomb_target" ] || printf 'uninstall %s\n' "$run_tomb_item"
  done <"$run_tmp/tombstones" >>"$run_tmp/removals"
  run_removals_held=$(fleet_run_removals_over "$run_tmp/removals" \
    "$(fleet_applied_count "$run_store" "$run_host")" "$run_fold")
  run_cap_over=false
  [ -z "$run_removals_held" ] || run_cap_over=true
  fleet_alert_set "$run_store" "$run_host" removal-cap removal-cap "$run_cap_over" \
    "over the removal cap, held whole: $(printf '%s\n' "$run_removals_held" |
      awk '{ n[$1]++ } END { for (t in n) printf "%s%d %s", (s++ ? ", " : ""), n[t], t }')" ||
    :
  run_uninstalls_ok=true
  ! printf '%s\n' "$run_removals_held" | grep -q '^uninstall ' || run_uninstalls_ok=false
  printf '%s\n' "$run_removals_held" | grep -q '^prune ' ||
    awk '$1 == "prune" { sub(/^prune /, ""); print }' "$run_tmp/removals" |
    while IFS= read -r run_owned; do
    [ -n "$run_owned" ] || continue
    printf '  prune %s (in applied/, gone from the layers)\n' "$run_owned"
    fleet_applied_forget "$run_store" "$run_host" "$run_owned"
    fleet_journal_append "$run_store" "$run_host" \
      "$(jq -cn --arg item "$run_owned" --arg at "$run_now" \
        '{item:$item,digest:"absent",outcome:"reverted",at:$at}')" || :
  done

  # Plugins are always current: marketplaces whose upstream moved (fast), or
  # all of them (full), are refreshed BEFORE the plan, so this pass's identity
  # comparison sees the new catalog and updates the plugin items it owns
  # (lib/fleet-plugins.sh). The stamp keeps the full pass from refreshing
  # them a second time. On conflicted heads the fold and definitions are the
  # first head's alone, so a plugin another head owns would read as unowned and
  # be updated in place past its hold: the refresh waits for the resolution.
  if [ "$run_state" = conflicted ]; then
    printf '  hold  plugins — conflicted heads; the marketplace refresh waits for the resolution\n'
  else
    fleet_plugins_refresh "$run_store" "$run_host" "$run_fold" "$run_defs" \
      "$run_mode" "$run_tmp" "$run_desired" || :
  fi
  : >"$run_tmp/plugins-refreshed"

  # The pass's whole item set, for the sweep's retired-item rule.
  awk 'NF >= 2 { print $2 }' "$run_tmp/verdicts" | fleet_alert_items "$run_ledger"
  # THE PLAN, not one lookup per item: every per-item read below — value,
  # applied/ digest, review hold, revert signature, signature hold — answered
  # once for the whole verdict list (fleet_run_item_plan), and every write
  # queued and landed once per file after the loop (fleet_run_batch_*).
  fleet_run_item_plan "$run_store" "$run_host" "$run_desired" "$run_tmp/verdicts" \
    "$run_tmp/sigholds" >"$run_tmp/plan"
  # The host's managers, the canary verdicts and the package snapshot do not
  # change while the loop runs, so they are asked once rather than per item.
  run_managers=$(fleet_run_package_managers "$run_fold" "$run_host")
  : >"$run_tmp/canary-pass"
  if [ "$run_self_canary" != true ] && [ -s "$run_tmp/canaries" ]; then
    # shellcheck disable=SC2046 # the canary set, one host per argument
    fleet_run_canary_passing "$run_store" "$run_wait" "$run_now" "$run_tmp/plan" \
      $(cat "$run_tmp/canaries") >"$run_tmp/canary-pass"
  fi
  fleet_run_apply_context_open "$run_tmp/apply-context" "$run_defs" "$run_managers" \
    "$run_tmp/plan"
  run_holds_grew=false
  run_action_memo='|'
  fleet_run_batch_open "$run_tmp/batch"
  # THE PLAN IS READ ON FD 9, not on stdin. This loop's body runs
  # `brew`, `claude` and `git clone`; measured, one greedy child consumed the
  # rest of the list and silently cut a four-item run to one.
  while IFS="$fleet_run_sep" read -r run_verdict run_item run_digest run_value \
    run_applied run_review_held run_revert run_state run_hold <&9; do
    [ -n "${run_item:-}" ] || continue
    if [ "$run_verdict" = held ]; then
      fleet_run_runtime_hold "$run_item" 'verdict held' "$run_tmp/sigholds" || {
        fleet_run_batch_close "$run_store" "$run_host"
        exit 65
      }
      run_holds_grew=true
      fleet_run_journal_queue "$run_store" "$run_host" "$run_item" held held \
        "$run_now" || :
      continue
    fi
    # The plan's hold field is the lookup as of the loop's start; once this
    # loop has added a hold line (a definitions refusal holds its consumer
    # later in the list), the lookup is made again, as it always was.
    if [ "$run_holds_grew" = true ]; then
      run_hold=$(awk -v item="$run_item" '$1 == item { $1 = ""; print; exit }' \
        "$run_tmp/sigholds")
    fi
    fleet_alert_checked "$run_ledger" integrity "$run_item"
    if [ -n "$run_hold" ]; then
      printf '  hold  %s —%s\n' "$run_item" "$run_hold"
      fleet_alert_raise "$run_ledger" "$run_store" "$run_host" integrity \
        "integrity-$(printf '%s' "$run_item" | tr './' '--')" \
        "$run_item held:$run_hold" "$run_item" || :
      fleet_run_journal_queue "$run_store" "$run_host" "$run_item" "$run_digest" \
        held "$run_now" || :
      continue
    fi
    # §7.6's supervised half: a human `fleet-review ITEM hold` refuses THIS
    # value, and it outranks every gate below it — there is no point waiting for
    # canary evidence about a digest someone has already looked at and refused.
    # Host-local, like every verdict: the refusal governs this machine and is
    # never a vote cast on anyone else's behalf.
    if [ "$run_review_held" = 1 ]; then
      printf '  hold  %s — held by review at %s\n' "$run_item" "$run_digest"
      fleet_run_runtime_hold "$run_item" 'held by review' "$run_tmp/sigholds" || {
        fleet_run_batch_close "$run_store" "$run_host"
        exit 65
      }
      run_holds_grew=true
      fleet_run_journal_queue "$run_store" "$run_host" "$run_item" "$run_digest" \
        held "$run_now" || :
      continue
    fi

    # fleet_item_split's category, in-shell; the value is the plan's (read
    # from the desired document, as fleet_item_value read it).
    case $run_item in
      definitions.*.*)
        run_category=${run_item#definitions.}
        run_category=definitions.${run_category%%.*}
        ;;
      *.*) run_category=${run_item%%.*} ;;
      *) continue ;;
    esac

    # §3.4: a TOMBSTONE converges by uninstalling. It is never recorded in
    # applied/ — that record means "installed and owned", and a recorded
    # tombstone would read as a prune the day the tombstone is compacted away.
    # A host that already converged this digest and still has nothing
    # installed has nothing to say about it, so it says nothing.
    run_tombstone=false
    run_tomb_removal=false
    if grep -Fqx "$run_item" "$run_tmp/tombstones"; then
      run_tombstone=true
      ! grep -Fqx "uninstall $run_item" "$run_tmp/removals" || run_tomb_removal=true
      if [ "$run_tomb_removal" = false ] &&
        [ "$(cat "$(fleet_run_tombstone_memo_path "$run_item")" 2>/dev/null)" = \
          "$run_digest" ] &&
        [ -z "$(fleet_applied_digest "$run_store" "$run_host" "$run_item")" ]; then
        continue
      fi
      if [ "$run_tomb_removal" = true ] && [ "$run_uninstalls_ok" != true ]; then
        printf '  hold  %s — the removal set is over the cap\n' "$run_item"
        fleet_run_runtime_hold "$run_item" 'removal cap' "$run_tmp/sigholds" || {
          fleet_run_batch_close "$run_store" "$run_host"
          exit 65
        }
        run_holds_grew=true
        fleet_run_journal_queue "$run_store" "$run_host" "$run_item" "$run_digest" \
          held "$run_now" || :
        continue
      fi
    fi

    # §10.3's ownership table, as one function with one answer per row.
    run_in_applied=no
    [ -z "$run_applied" ] || run_in_applied=yes
    run_match=no
    [ "$run_applied" != "$run_digest" ] || run_match=yes
    if [ "$run_category" = plugins ] && [ "$run_in_applied" = yes ] &&
      [ "$run_match" = yes ]; then
      run_plugin_identity_status=0
      fleet_alert_checked "$run_ledger" identity-unavailable "$run_item"
      fleet_run_plugin_identity_matches "$run_defs" "${run_item#plugins.}" \
        "$run_value" || run_plugin_identity_status=$?
      case $run_plugin_identity_status in
        1) run_match=no ;;
        75)
          run_retry_owed=true
          printf '  hold  %s — installed marketplace identity unavailable (%s)\n' \
            "$run_item" "${fleet_run_identity_reason:-unproven}"
          fleet_run_runtime_hold "$run_item" \
            "installed marketplace identity unavailable: ${fleet_run_identity_reason:-unproven}" \
            "$run_tmp/sigholds" || {
            fleet_run_batch_close "$run_store" "$run_host"
            exit 65
          }
          run_holds_grew=true
          fleet_alert_raise "$run_ledger" "$run_store" "$run_host" \
            identity-unavailable identity-unavailable \
            "$(printf '%s' "installed marketplace identity unavailable: ${fleet_run_identity_reason:-unproven}" | head -c 380)" \
            "$run_item" || :
          fleet_run_journal_queue "$run_store" "$run_host" "$run_item" \
            "$run_digest" held "$run_now" || :
          continue
          ;;
      esac
    fi
    # ponytail: on-host observation exists for no category yet (declared
    # boundary B-3), so row 2 reads as row 1 — adopt, which reviews before it
    # applies. Wrong in the safe direction; the dangerous row (not ours, never
    # touch it) is driven by applied/ and is exact.
    # fleet_ownership_action is a pure table over these two answers: asked
    # once per distinct pair a run sees, not once per item.
    case $run_action_memo in
      *"|$run_in_applied$run_match="*)
        run_action=${run_action_memo#*"|$run_in_applied$run_match="}
        run_action=${run_action%%"|"*}
        ;;
      *)
        run_action=$(fleet_ownership_action yes "$run_in_applied" no "$run_match")
        run_action_memo="$run_action_memo$run_in_applied$run_match=$run_action|"
        ;;
    esac
    [ "$run_action" != nothing ] || continue

    # §10.8: a revert restores a value this host already passed before, so a
    # verdict keyed on (item, digest) alone matches a stale pass. Re-review is
    # the point, and it must be visible.
    run_reason="$run_action at $run_digest"
    if [ "$run_revert" = 1 ]; then
      run_reason="revert re-reviewed: this host applied $run_digest before and withdrew it"
      printf '  revert %s — re-reviewing, not matching the stored verdict\n' "$run_item"
    fi

    # §10.1's gate, with the liveness term. Canary hosts are not gated by
    # themselves, a tombstone with nothing installed here is not a change
    # here (its `satisfied` is true whatever the canaries have seen), and a
    # plugin is never gated: plugins are always current (fleet_canary_exempt).
    if [ "$run_self_canary" != true ] && [ -s "$run_tmp/canaries" ] &&
      ! fleet_canary_exempt "$run_item" &&
      { [ "$run_tombstone" != true ] || [ "$run_tomb_removal" = true ]; }; then
      # fleet_canary_gate's answer for every plan item was computed before
      # the loop (fleet_run_canary_passing): the canaries' journals do not
      # change while this host applies.
      grep -Fqx "$run_item$fleet_run_sep$run_digest" "$run_tmp/canary-pass" || {
        run_canary_waiting=true
        printf '  wait  %s — no canary evidence at %s yet\n' "$run_item" "$run_digest"
        fleet_run_runtime_hold "$run_item" 'canary evidence unavailable' \
          "$run_tmp/sigholds" || {
          fleet_run_batch_close "$run_store" "$run_host"
          exit 65
        }
        run_holds_grew=true
        fleet_run_journal_queue "$run_store" "$run_host" "$run_item" \
          "$run_digest" held "$run_now" || :
        continue
      }
    fi

    # §6 step 5: the review is provenance, not a file diff — and it prints
    # BEFORE the apply, so a crash mid-apply still leaves the operator the
    # value and digest that were about to be written.
    printf '  review %s  %s  %s\n' "$run_item" "${run_value:-<none>}" "$run_digest"
    fleet_run_verdict_write "$run_item" "$run_digest" "$run_reason"
    run_status=0
    if [ "$run_tombstone" = true ]; then
      # The uninstall journals on its own: land what is queued first, so the
      # journal keeps the per-item order.
      fleet_run_batch_flush "$run_store" "$run_host"
      fleet_alert_checked "$run_ledger" uninstall-deferred "$run_item"
      fleet_run_tombstone_converge "$run_store" "$run_host" "$run_defs" \
        "$run_item" "$run_value" "$run_digest" "$run_now" || run_status=$?
      # A live-session deferral is a condition with a record of its own; the
      # alert stands while the record does, and says which side of the 24h
      # window it is on.
      if [ "$run_status" -eq 75 ] && [ -f "$(fleet_run_deferral_path "$run_item")" ]; then
        run_defer_first=$(awk '{ print $2; exit }' "$(fleet_run_deferral_path "$run_item")")
        case $run_defer_first in '' | *[!0-9]*) run_defer_first=0 ;; esac
        if [ "$((run_defer_first + 86400))" -gt "$(date +%s)" ]; then
          run_defer_detail="$run_item is enabled and a claude session is running; its uninstall waits up to 24h from the first deferral"
        else
          run_defer_detail="$run_item: the 24h live-session window has passed and the uninstall still fails; every fast pass retries it (it keeps the poll floor open)"
        fi
        fleet_alert_raise "$run_ledger" "$run_store" "$run_host" \
          uninstall-deferred uninstall-deferred "$run_defer_detail" "$run_item" || :
      fi
      # Converged either way — uninstalled (0) or already absent (70) — and,
      # like any applied or satisfied item, that is evidence a canary owes
      # its heartbeat for (run_applied_any).
      case $run_status in
        0)
          run_applied_items="$run_applied_items$run_item "
          run_applied_any=true
          continue
          ;;
        70)
          run_applied_any=true
          continue
          ;;
      esac
    else
      case $run_category in
        packages)
          fleet_alert_checked "$run_ledger" package-hold "$run_item"
          fleet_alert_checked "$run_ledger" package-deferred "$run_item"
          ;;
        hooks) fleet_alert_checked "$run_ledger" enabled-but-untrusted "$run_item" ;;
        runtimes)
          fleet_alert_checked "$run_ledger" runtime-hold "$run_item"
          fleet_alert_checked "$run_ledger" node-runtime-unverified "$run_item"
          ;;
      esac
      # The hook gate reads `plugins.<p>` from applied/: land what is queued
      # first, so it sees exactly what the per-item writes would have shown it.
      [ "$run_category" != hooks ] ||
        fleet_run_batch_flush "$run_store" "$run_host" applied-only
      fleet_run_apply_item "$run_store" "$run_host" "$run_defs" "$run_item" \
        "$run_value" "$run_managers" "$run_state" || run_status=$?
    fi
    case $run_status in
      0)
        # An unwritable applied/<h>.yaml is loud and narrow, never fatal: the
        # record refuses rather than truncating (fleet_record_write), and a
        # bare call under `set -e` would abort the run mid-apply instead of
        # narrowing what is applicable.
        fleet_alert_checked "$run_ledger" record-write "$run_item"
        fleet_run_applied_queue "$run_store" "$run_host" "$run_item" "$run_digest" \
          "$run_now" || {
          printf 'roundhouse: could not record %s in applied/%s.yaml; the item is applied but unowned\n' \
            "$run_item" "$run_host" >&2
          fleet_alert_raise "$run_ledger" "$run_store" "$run_host" record-write \
            "record-write-$(printf '%s' "$run_item" | tr './' '--')" \
            "applied/$run_host.yaml could not be updated for $run_item" \
            "$run_item" || :
        }
        fleet_run_journal_queue "$run_store" "$run_host" "$run_item" "$run_digest" \
          applied "$run_now" || :
        run_applied_items="$run_applied_items$run_item "
        run_applied_any=true
        printf '  applied %s\n' "$run_item"
        # Self-test only: abort the pass right after this item applied, so the
        # self-check can prove the queued records still land.
        if fleet_test_hook "${ROUNDHOUSE_FLEET_TEST_ABORT_AFTER_APPLY:-}" &&
          [ "$run_item" = "$ROUNDHOUSE_FLEET_TEST_ABORT_AFTER_APPLY" ]; then
          printf 'roundhouse: self-test abort after applying %s\n' "$run_item" >&2
          false
        fi
        ;;
      70)
        # No-op BECAUSE CORRECT: the item resolved and reviewed, and this
        # design has no state-alignment verb to run for it (B-3). A DISTINCT
        # outcome from `held` so an audit can tell the two apart, and the one
        # non-`applied` outcome the canary gate accepts as evidence —
        # otherwise every such item deadlocks the whole fleet behind a record
        # that can never be written. applied/ stays untouched: nothing was
        # installed, so nothing is owned, and §10.3's removal legality is
        # unchanged.
        fleet_run_journal_queue "$run_store" "$run_host" "$run_item" "$run_digest" \
          satisfied "$run_now" || :
        run_applied_any=true
        printf '  satisfied %s (no state-alignment verb for this category)\n' \
          "$run_item"
        ;;
      *)
        # A FAILED apply, or a TRANSIENT hold, owes a retry next pass: the
        # poll floor stays open for it (fleet_run_hold_owes_retry names which
        # holds are transient and which are standing).
        ! fleet_run_hold_owes_retry "$run_status" "$run_tombstone" ||
          run_retry_owed=true
        run_holds_grew=true
        fleet_run_apply_held "$run_store" "$run_host" "$run_defs" "$run_item" \
          "$run_category" "$run_digest" "$run_status" "$run_tmp" "$run_now" "$run_managers" || {
          fleet_run_batch_close "$run_store" "$run_host"
          exit 65
        }
        ;;
    esac
  done 9<"$run_tmp/plan"
  fleet_run_batch_close "$run_store" "$run_host"
  fleet_run_apply_context_close
  for run_marker in canary-waiting retry-owed; do
    case $run_marker in
      canary-waiting) run_marker_set=$run_canary_waiting ;;
      *) run_marker_set=$run_retry_owed ;;
    esac
    if [ "$run_marker_set" = true ]; then
      : >"$(fleet_run_state_dir)/$run_marker"
    else
      rm -f "$(fleet_run_state_dir)/$run_marker"
    fi
  done

  # --- the full cadence's maintenance half ---
  if [ "$run_mode" = full ]; then
    fleet_run_full_pass "$run_store" "$run_host" "$run_fold" "$run_defs" \
      "$run_layers" "$run_tmp"
  fi

  # The end of the pass: every item-scoped CONDITION alert whose item this
  # pass checked and did not raise has ended (fleet_alert_sweep, over the
  # table's item-scoped kinds). An item the pass skipped keeps its alert.
  fleet_alert_sweep "$run_store" "$run_host" "$run_ledger"

  # §10.1 condition 3's heartbeat: a canary that applies an item, is wrecked by
  # it and stops journaling otherwise satisfies conditions 1 and 2. A record
  # per completed run is what makes silence visible — host-local on every
  # pass, and PUBLISHED only when §6.3's throttle, an apply, or a canary
  # evidence deadline calls for it (lib/fleet-liveness.sh). Publishing it on
  # every pass was a record commit per host per pass, which is what defeated
  # every peer's poll floor.
  run_alive_at=$(fleet_now)
  fleet_heartbeat_local "$run_alive_at" || :
  # §6.3's other half: a peer with no published heartbeat inside
  # `liveness_alert_hours` is alerted on, from this store's journal alone.
  fleet_liveness_alerts "$run_store" "$run_host" "$run_tmp/hosts" \
    "$run_tmp/reviewed-roster" "$run_fold" "$run_alive_at" \
    "$(fleet_vcs_heads_local "$run_store" | head -1)" |
    while read -r _ run_silent; do
      printf 'roundhouse: %s has published no heartbeat within liveness_alert_hours (stale-host alert)\n' \
        "$run_silent" >&2
    done || :
  fleet_heartbeat_publish "$run_store" "$run_host" "$run_alive_at" "$run_fold" \
    "$run_self_canary" "$run_applied_any" "$run_wait" || :

  # §8.4: while a conflict is open the host is locally converging and
  # PUBLICATION-SILENT — the same state it is in when offline.
  if [ "$run_state" = conflicted ]; then
    printf 'roundhouse: converged locally; publication held while the conflict is open (§8.4)\n'
    printf 'roundhouse: starting operation %s (not pushed)\n' "$run_op"
    exit 0
  fi
  if [ "$run_fetched" != true ]; then
    # §6/convergence.md: an unreachable remote is JOURNALED as `source: none`,
    # not only printed to stderr. The record is the durable, replicated evidence
    # that this host converged from last known on this run — a peer reading the
    # journal can tell "was dark, converged locally" from "never ran". It rides
    # the next successful publish, exactly like every other local commit.
    fleet_journal_append "$run_store" "$run_host" \
      "$(jq -cn --arg at "$(fleet_now)" \
        '{outcome:"unreachable",source:"none",at:$at}')" || :
    printf 'roundhouse: converged from last known; nothing published (the remote was unreachable, journaled source: none)\n'
    exit 0
  fi
  fleet_run_publish "$run_store" "$run_host" scheduled/agent \
    "$run_mode convergence" "${run_applied_items:--}" || exit $?
  # The poll floor's converged-here condition and its comparison base: the
  # head this host now sits on, and the desired state of the reference it
  # converged FROM (fleet_run_poll_floor says why it is not the head's).
  fleet_vcs_heads_local "$run_store" >"$(fleet_run_state_dir)/converged"
  fleet_vcs_desired_digest "$run_store" "$run_reference" \
    >"$(fleet_run_state_dir)/converged-desired" 2>/dev/null ||
    rm -f "$(fleet_run_state_dir)/converged-desired"
  printf 'roundhouse: published; starting operation %s\n' "$run_op"
  # §6.1: nudge only when this publish moved DESIRED STATE past what arrived
  # at the start of the pass. A records-only publish is not news a peer needs
  # pushed to it — and two hosts waiting on the same canary would otherwise
  # nudge each other every pass for the whole wait.
  #
  # The off-switch is a policy key like any other, and its absence reads as
  # "on" — an accelerator you cannot turn off is a dependency.
  if fleet_vcs_desired_changed "$run_store" "$run_pre_origin" \
    "$(fleet_vcs_heads_local "$run_store" | head -1)"; then
    [ "$(fleet_policy_get "$run_fold" push_nudge 2>/dev/null || printf true)" = false ] ||
      fleet_run_nudge "$run_store" "$run_host" "$run_layers" \
        "$(fleet_run_interval_seconds "$run_fold" "$run_host" fast)" || :
  fi
}

fleet_run_resolve_conflict() (
  # fleet_run_resolve_conflict STORE HOST TMP FOLD HEADS
  #
  # §8.2b step 3b: gather the evidence, decide, write the resolution into @ (a
  # child of M). The ladder itself lives in lib/fleet-resolve.sh and takes its
  # evidence as DATA; this function's whole job is assembling that data
  # honestly and turning a verdict into bytes.
  #
  # ponytail: the resolution is written at FILE granularity — a conflicted
  # layer file is taken whole from the winning side. Adjacent-line collisions
  # (the common case) all decide rule 1 and agree, so this costs nothing; a
  # file whose items split across sides escalates instead of being merged
  # key-by-key. Upgrade to a per-key rewrite if a real fleet ever hits it.
  resolve_store=$1
  resolve_host=$2
  resolve_tmp=$3
  resolve_fold=$4
  # shellcheck disable=SC2086 # deliberate word splitting over the head list
  set -- $5
  [ $# -eq 2 ] || {
    printf 'roundhouse: %s heads on a conflicted bookmark; escalating rather than arbitrating\n' "$#" >&2
    # On the REPLICATED alert surface too, like every other escalation: a
    # three-way bookmark conflict that only reaches stderr is invisible to
    # `fleet-pending` and to every peer.
    fleet_alert_write "$resolve_store" "$resolve_host" conflict \
      conflict-multiple-heads \
      "$# heads on the main bookmark; escalating rather than arbitrating (§8.2b)" ||
      :
    return 1
  }
  resolve_origin=$(fleet_vcs_head_origin "$resolve_store")
  if [ "$1" = "$resolve_origin" ]; then
    resolve_theirs=$1
    resolve_mine=$2
    resolve_theirs_dir=$resolve_tmp/head-1
    resolve_mine_dir=$resolve_tmp/head-2
  else
    resolve_mine=$1
    resolve_theirs=$2
    resolve_mine_dir=$resolve_tmp/head-1
    resolve_theirs_dir=$resolve_tmp/head-2
  fi
  resolve_interval=$(fleet_run_interval_seconds "$resolve_fold" "$resolve_host" fast)
  : >"$resolve_tmp/sides"
  : >"$resolve_tmp/escalated"
  grep '^held ' "$resolve_tmp/verdicts" | while read -r _ resolve_item; do
    [ -n "$resolve_item" ] || continue
    resolve_evidence=$(fleet_run_evidence "$resolve_item" "$resolve_interval" \
      "$(fleet_run_side "$resolve_store" "$resolve_mine" "$resolve_item" \
        "$resolve_host" "$resolve_tmp/hosts" "$resolve_tmp" "$resolve_mine_dir" \
        "$resolve_theirs")" \
      "$(fleet_run_side "$resolve_store" "$resolve_theirs" "$resolve_item" \
        "$resolve_host" "$resolve_tmp/hosts" "$resolve_tmp" "$resolve_theirs_dir" \
        "$resolve_mine")")
    resolve_decision=$(printf '%s\n' "$resolve_evidence" | fleet_resolve_decide)
    resolve_verdict=$(printf '%s\n' "$resolve_decision" | jq -r '.verdict')
    resolve_rule=$(printf '%s\n' "$resolve_decision" | jq -r '.rule')
    resolve_why=$(printf '%s\n' "$resolve_decision" | jq -r '.rationale')
    if [ "$resolve_verdict" = escalate ]; then
      printf '  hold  %s — rule %s: %s\n' "$resolve_item" "$resolve_rule" "$resolve_why"
      fleet_alert_write "$resolve_store" "$resolve_host" conflict \
        "conflict-$(printf '%s' "$resolve_item" | tr './' '--')" \
        "rule $resolve_rule: $resolve_why" "$resolve_item" || :
      printf '%s\n' "$resolve_item" >>"$resolve_tmp/escalated"
      continue
    fi
    resolve_side=mine
    [ "$resolve_verdict" != theirs ] || resolve_side=theirs
    resolve_path=$(fleet_run_item_layer "$resolve_mine_dir" "$resolve_host" \
      "$resolve_item" 2>/dev/null) ||
      resolve_path=$(fleet_run_item_layer "$resolve_theirs_dir" "$resolve_host" \
        "$resolve_item" 2>/dev/null) || continue
    printf '%s\t%s\t%s\t%s\t%s\n' "$resolve_path" "$resolve_side" \
      "$resolve_item" "$resolve_rule" "$resolve_why" >>"$resolve_tmp/sides"
  done

  [ ! -s "$resolve_tmp/escalated" ] || return 1
  [ -s "$resolve_tmp/sides" ] || return 1
  : >"$resolve_tmp/resolved"
  rm -f "$resolve_tmp/split"
  # A `return` inside a pipeline's `while` leaves the pipeline's subshell, not
  # this function, so the split-file refusal travels as a file.
  cut -f1 "$resolve_tmp/sides" | LC_ALL=C sort -u |
    while IFS= read -r resolve_path; do
      [ -n "$resolve_path" ] || continue
      resolve_choice=$(awk -F'\t' -v p="$resolve_path" \
        '$1 == p { print $2 }' "$resolve_tmp/sides" | LC_ALL=C sort -u)
      [ "$(printf '%s\n' "$resolve_choice" | grep -c .)" -eq 1 ] || {
        printf 'roundhouse: %s carries items resolving to both sides; escalating\n' \
          "$resolve_path" >&2
        : >"$resolve_tmp/split"
        continue
      }
      resolve_head=$resolve_mine
      [ "$resolve_choice" != theirs ] || resolve_head=$resolve_theirs
      mkdir -p "$resolve_store/$(dirname "$resolve_path")"
      jj -R "$resolve_store" file show -r "$resolve_head" "root:$resolve_path" \
        >"$resolve_store/$resolve_path"
      awk -F'\t' -v p="$resolve_path" '$1 == p { print $3 }' "$resolve_tmp/sides" \
        >>"$resolve_tmp/resolved"
    done
  [ ! -f "$resolve_tmp/split" ] || return 1
  [ -s "$resolve_tmp/resolved" ] || return 1

  # §5's one replicated record that carries a rationale, and the exception that
  # proves the rule: a hold reason is duplicated in store.run/, but a
  # resolution is a fleet-affecting decision no other artifact records. Peers
  # must be able to see why.
  #
  # STAGED, NOT APPENDED. The fold that makes the resolution real
  # (fleet_vcs_fold_resolution) runs in the CALLER and can still refuse — the
  # merge may come back conflicted — so writing `outcome: resolved` here
  # published a record, to every peer, for an item that was still held. The
  # caller appends these once the fold has succeeded.
  : >"$resolve_tmp/resolution-journal"
  while IFS= read -r resolve_item; do
    [ -n "$resolve_item" ] || continue
    resolve_row=$(awk -F'\t' -v i="$resolve_item" '$3 == i { print; exit }' \
      "$resolve_tmp/sides")
    printf '%s\n' \
      "$(jq -cn --arg item "$resolve_item" \
        --arg digest "$(fleet_item_digest "$resolve_fold" "$resolve_item" 2>/dev/null || printf unknown)" \
        --arg mine "$(jj -R "$resolve_store" log -r "$resolve_mine" --no-graph -T 'change_id')" \
        --arg theirs "$(jj -R "$resolve_store" log -r "$resolve_theirs" --no-graph -T 'change_id')" \
        --arg host "$resolve_host" \
        --arg resolution "rule $(printf '%s' "$resolve_row" | cut -f4): $(printf '%s' "$resolve_row" | cut -f5)" \
        --arg at "$(fleet_now)" \
        '{item:$item,digest:$digest,outcome:"resolved",
          sides:[{change:$mine,host:$host},{change:$theirs,host:"peer"}],
          resolution:$resolution,at:$at}')" >>"$resolve_tmp/resolution-journal"
  done <"$resolve_tmp/resolved"
)

fleet_run_resolution_journal() {
  # fleet_run_resolution_journal STORE HOST TMP — append the resolution records
  # fleet_run_resolve_conflict staged, once the fold that made them true has
  # succeeded.
  [ -f "$3/resolution-journal" ] || return 0
  while IFS= read -r fleet_run_res_entry; do
    [ -n "$fleet_run_res_entry" ] || continue
    fleet_journal_append "$1" "$2" "$fleet_run_res_entry" || :
  done <"$3/resolution-journal"
  rm -f "$3/resolution-journal"
}

fleet_run_item_is_held() {
  # fleet_run_item_is_held ITEM DIGEST SIGNATURE_HOLDS VERDICTS. The full
  # cadence runs after the apply loop, so it must not consume a definition or
  # desired plugin that this run already held. Otherwise maintenance could
  # act on content the item gate deliberately refused.
  [ -f "$3" ] && awk -v item="$1" '$1 == item { found = 1 } END { exit !found }' \
    "$3" && return 0
  [ -f "$4" ] && awk -v item="$1" \
    '$1 == "held" && $2 == item { found = 1 } END { exit !found }' \
    "$4" && return 0
  [ -n "$2" ] && fleet_run_verdict_held "$1" "$2" && return 0
  return 1
}

fleet_run_review_holds() {
  # stdin `<item>\t<digest>` -> the items fleet_run_verdict_held ITEM DIGEST
  # answers true for, every verdict file read in one yq: a hold only when the
  # file carries exactly one `hold` document with a digest, and it is this
  # digest — what the per-item comparison of the whole output decided.
  # Non-zero when the batch read fails; the caller then asks per item.
  rh_tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-holds.XXXXXX") || return 1
  rh_vdir=$(fleet_run_state_dir)/verdicts
  : >"$rh_tmp/files"
  while IFS='	' read -r rh_item rh_digest; do
    [ -n "$rh_item" ] && [ -n "$rh_digest" ] || continue
    [ ! -f "$rh_vdir/$rh_item.yaml" ] ||
      printf '%s\t%s\t%s\n' "$rh_vdir/$rh_item.yaml" "$rh_item" "$rh_digest" >>"$rh_tmp/files"
  done
  rh_ok=true
  : >"$rh_tmp/holds"
  if [ -s "$rh_tmp/files" ]; then
    # xargs execs yq, bypassing the function: see select_mikefarah_yq.
    cut -f1 "$rh_tmp/files" | tr '\n' '\0' |
      xargs -0 "${ROUNDHOUSE_YQ:-yq}" -o=json -I=0 '{"f": filename, "v": (.verdict // ""), "d": (.digest // "")}' \
        >"$rh_tmp/verdicts.json" 2>/dev/null || rh_ok=false
    [ "$rh_ok" = false ] ||
      jq -r 'select(.v == "hold" and .d != "") | "\(.f)\t\(.d | tostring)"' \
        <"$rh_tmp/verdicts.json" >"$rh_tmp/holds" 2>/dev/null || rh_ok=false
  fi
  [ "$rh_ok" = true ] && LC_ALL=C awk -F'\t' '
    FILENAME == ARGV[1] { n[$1]++; d[$1] = $2; next }
    n[$1] == 1 && d[$1] == $3 { print $2 }' "$rh_tmp/holds" "$rh_tmp/files"
  rm -rf "$rh_tmp"
  [ "$rh_ok" = true ]
}

fleet_run_items_held() {
  # fleet_run_items_held HOLDS VERDICTS < `<item>\t<digest>` -> the items
  # fleet_run_item_is_held ITEM DIGEST HOLDS VERDICTS answers true for, in
  # one pass: a line naming the item in HOLDS, a `held <item>` verdict, or a
  # review hold at that digest.
  ih_tmp=$(mktemp "${TMPDIR:-/tmp}/roundhouse-held.XXXXXX") || return 1
  cat >"$ih_tmp"
  if ! ih_review=$(fleet_run_review_holds <"$ih_tmp"); then
    while IFS='	' read -r ih_item ih_digest; do
      [ -z "$ih_digest" ] || ! fleet_run_verdict_held "$ih_item" "$ih_digest" ||
        printf '%s\n' "$ih_item"
    done <"$ih_tmp" >"$ih_tmp.review"
    ih_review=$(cat "$ih_tmp.review")
    rm -f "$ih_tmp.review"
  fi
  # A HOLDS or VERDICTS that is not a file is skipped, as `[ -f ]` skipped it;
  # both are split on whitespace, as the per-item awk read them. Each input is
  # its own named file, so an empty one cannot shift which rule reads which.
  : >"$ih_tmp.holds"
  [ -z "${1:-}" ] || [ ! -f "$1" ] || cat "$1" >"$ih_tmp.holds"
  : >"$ih_tmp.verdicts"
  [ -z "${2:-}" ] || [ ! -f "$2" ] || cat "$2" >"$ih_tmp.verdicts"
  printf '%s\n' "$ih_review" >"$ih_tmp.review"
  LC_ALL=C awk -F'\t' '
    FILENAME == ARGV[1] { if ($0 != "") review[$0] = 1; next }
    FILENAME == ARGV[2] { split($0, f, " "); holds[f[1]] = 1; next }
    FILENAME == ARGV[3] { split($0, f, " "); if (f[1] == "held") held[f[2]] = 1; next }
    ($1 in holds) || ($1 in held) || ($1 in review) { print $1 }
  ' "$ih_tmp.review" "$ih_tmp.holds" "$ih_tmp.verdicts" "$ih_tmp"
  rm -f "$ih_tmp" "$ih_tmp.review" "$ih_tmp.holds" "$ih_tmp.verdicts"
}

fleet_run_definition_hold_consumers() {
  # fleet_run_definition_hold_consumers HOLDS VERDICTS VALUES TMP — a definitions
  # refusal also holds the desired item that would resolve through it. The
  # mapping is one-to-one by design: definitions.packages.foo governs
  # packages.foo, and the same shape applies to agent-surface categories.
  # This protects both a changed mapping and a deleted mapping, whose current
  # tree no longer has an entry from which a resolver could detect the hold.
  fleet_run_definition_hold_items=$4/definition-hold-items
  awk '$1 != "" && $1 != "!hold" { print $1 }' "$1" \
    >"$fleet_run_definition_hold_items"
  awk '$1 == "held" { print $2 }' "$2" \
    >>"$fleet_run_definition_hold_items"
  fleet_run_definition_consumer_holds=$4/definition-consumer-holds
  : >"$fleet_run_definition_consumer_holds"
  while IFS= read -r fleet_run_definition_hold; do
    fleet_run_definition_item=${fleet_run_definition_hold%% *}
    case $fleet_run_definition_item in
      definitions.*.*)
        fleet_run_definition_rest=${fleet_run_definition_item#definitions.}
        fleet_run_definition_category=${fleet_run_definition_rest%%.*}
        fleet_run_definition_name=${fleet_run_definition_rest#*.}
        [ -n "$fleet_run_definition_category" ] || continue
        [ -n "$fleet_run_definition_name" ] || continue
        fleet_run_definition_consumer=$fleet_run_definition_category.$fleet_run_definition_name
        awk -v item="$fleet_run_definition_consumer" \
          '$1 == item { found = 1 } END { exit !found }' "$3" || continue
        printf '%s held by %s\n' "$fleet_run_definition_consumer" \
          "$fleet_run_definition_item" >>"$fleet_run_definition_consumer_holds"
        ;;
    esac
  done < <(LC_ALL=C sort -u "$fleet_run_definition_hold_items")
  [ ! -s "$fleet_run_definition_consumer_holds" ] || {
    LC_ALL=C sort -u "$fleet_run_definition_consumer_holds" \
      >>"$1"
  }
}

fleet_run_hold_items_into_verdicts() {
  # fleet_run_hold_items_into_verdicts HOLDS VERDICTS TMP — a held item that
  # vanished from every reviewed head still needs a verdict entry. Otherwise
  # the removal pass and the apply loop never see the hold: an existing host
  # can forget the item, while a new host can resolve a deleted definition by
  # its default. Preserve existing converge/held verdicts and add only the
  # missing held entries. A `converge` verdict for a held item is replaced, so
  # the removal and apply loops consume the same effective decision.
  fleet_run_hold_item_list=$3/held-items
  awk '$1 != "" && $1 != "!hold" { print $1 }' "$1" |
    LC_ALL=C sort -u >"$fleet_run_hold_item_list"
  fleet_run_held_verdicts=$3/held-verdicts
  awk '
    FILENAME == ARGV[1] { held[$1] = 1; next }
    {
      if ($2 in held) {
        print "held", $2
        emitted[$2] = 1
      } else {
        print
      }
    }
    END {
      for (item in held)
        if (!(item in emitted)) print "held", item
    }
  ' "$fleet_run_hold_item_list" "$2" |
    LC_ALL=C sort >"$fleet_run_held_verdicts"
  mv -f "$fleet_run_held_verdicts" "$2"
}

fleet_run_hold_owes_retry() {
  # fleet_run_hold_owes_retry STATUS TOMBSTONE — true when an apply that ended
  # STATUS (neither applied nor satisfied) owes a retry next pass, keeping the
  # poll floor open (retry-owed).
  #
  # The apply says which kind of hold it is; nothing here guesses from the
  # category. Any status other than a non-tombstone 75 owes a retry: every
  # failure, a deferral, and a TRANSIENT hold (74: a bounded manager verb or
  # query failed or timed out, fleet_run_apply_item). A 75 is a standing
  # "this host cannot" (no package manager provides the package, a hook this
  # host does not trust, no skill root or source, no `claude`), which only a
  # change elsewhere resolves, so the full cadence re-reads it. A tombstone's
  # 75s are the exception: its live-session deferral and its `ps` probe are
  # waits, not inabilities.
  [ "$1" = 75 ] || return 0
  [ "$2" = true ]
}

fleet_run_apply_held() {
  # fleet_run_apply_held STORE HOST DEFS ITEM CATEGORY DIGEST STATUS TMP NOW MANAGERS —
  # the run loop's answer to an apply that neither applied (0) nor was
  # satisfied (70): the run-local hold the full cadence consumes, the alert
  # that names why, the `held` journal entry, and the line. STATUS 73 is a
  # DEFERRAL rather than a refusal: the host can apply the item, but not
  # now, because a Node runtime switch is in flight or backing off on it
  # (lib/node-runtime.sh). It still journals `held`, and its hold line is
  # distinct so the full cadence's Node step can still make the retry the
  # backoff promises (fleet_run_full_node_runtime).
  fleet_run_runtime_hold "$4" "apply status $7" "$8/sigholds" || return 65
  [ "$5" != runtimes ] || fleet_run_node_alert "$8/alert-ledger" "$1" "$2" "$7" "$4"
  [ "$7" -ne 75 ] || [ "$5" != packages ] ||
    fleet_alert_raise "$8/alert-ledger" "$1" "$2" package-hold \
      "package-hold-$(printf '%s' "$4" | tr './' '--')" \
      "$(lane_package_hold_detail "$4" "$2" "$(fleet_run_resolve_package "$3" "${4#packages.}" "${10}" 2>/dev/null | jq -r '.manager // "none"')")" "$4" ||
    :
  [ "$7" -ne 73 ] || [ "$5" != packages ] ||
    fleet_alert_raise "$8/alert-ledger" "$1" "$2" package-deferred \
      "package-deferred-$(printf '%s' "$4" | tr './' '--')" \
      "$4 is not installed while a Node runtime switch is in flight on this host" "$4" ||
    :
  # §5.1.3's one carried-over behaviour: an enabled hook this host does
  # not trust is REPORTED by name, not silently skipped. The gate is
  # re-read for its reason rather than the apply path returning one,
  # because an exit status that carries prose is an exit status nobody
  # can test.
  [ "$7" -ne 75 ] || [ "$5" != hooks ] ||
    fleet_alert_raise "$8/alert-ledger" "$1" "$2" enabled-but-untrusted \
      "enabled-but-untrusted-$(printf '%s' "$4" | tr './' '--')" \
      "$(fleet_hook_trust "$1" "$2" "$3" "${4#hooks.}" || :)" "$4" ||
    :
  fleet_run_journal_queue "$1" "$2" "$4" "$6" held "$9" || :
  if [ "$7" -eq 73 ]; then
    printf '  held    %s (deferred: a Node runtime switch is in flight or backing off on this host)\n' "$4"
  elif [ "$7" -eq 74 ]; then
    printf '  held    %s (the manager failed or timed out; retried next pass)\n' "$4"
  else
    printf '  held    %s (this host could not apply it, or a gate refused)\n' "$4"
  fi
}

fleet_run_removals_over() {
  # fleet_run_removals_over REMOVALS APPLIED_COUNT FOLD -> the tagged lines of
  # the removal list that are OVER the cap, one per line (silence when within
  # it). The one over-cap rule both tags share, applied per tag, so a tag
  # over its cap holds whole and the other tag is untouched:
  #
  #   prune      fleet_removal_cap's two terms, as always: forgetting owned
  #              items is sized against how much this host owns.
  #   uninstall  max_removals_per_run alone. A tombstone uninstalls software
  #              this host may never have owned, so `applied × fraction` says
  #              nothing about its blast radius — and on a host that owns
  #              little it would hold every tombstone forever.
  removals_over_prunes=$(grep -c '^prune ' "$1" || true)
  removals_over_uninstalls=$(grep -c '^uninstall ' "$1" || true)
  fleet_removal_cap "$removals_over_prunes" "$2" \
    "$(fleet_policy_get "$3" max_removals_per_run)" \
    "$(fleet_policy_get "$3" max_removal_fraction)" >/dev/null ||
    grep '^prune ' "$1"
  [ "$removals_over_uninstalls" -le "$(fleet_policy_int "$3" max_removals_per_run)" ] ||
    grep '^uninstall ' "$1"
}

fleet_run_runtime_hold() {
  # fleet_run_runtime_hold ITEM REASON HOLDS_FILE — carry an apply-time
  # refusal into the same temporary hold surface the full cadence consumes.
  # This file is run-local and never replicated; the journal remains the audit
  # record, while this marker prevents maintenance in this same run from acting
  # on content the apply gate just refused.
  printf '%s %s\n' "$1" "$2" >>"$3"
  case $1 in
    definitions.*.*)
      fleet_run_runtime_definition_rest=${1#definitions.}
      fleet_run_runtime_definition_category=${fleet_run_runtime_definition_rest%%.*}
      fleet_run_runtime_definition_name=${fleet_run_runtime_definition_rest#*.}
      printf '%s held by %s: %s\n' \
        "$fleet_run_runtime_definition_category.$fleet_run_runtime_definition_name" \
        "$1" "$2" >>"$3"
      ;;
  esac
}

fleet_run_plugin_marketplaces() (
  # Resolve desired plugin marketplaces from the same surface resolver the
  # apply path uses. A marketplace may live in the definitions tier when the
  # desired value is the documented scalar `enabled`; refreshing only inline
  # values leaves that manifest stale forever.
  #
  # Every plugin's digest, its definition's digest and every hold among them
  # are read in one batch (fleet_value_digests, fleet_run_items_held), not
  # one handful of processes per plugin; the questions are the per-plugin
  # loop's, in its order.
  fleet_run_market_fold=$1
  fleet_run_market_defs=$2
  fleet_run_market_holds=${3:-}
  fleet_run_market_verdicts=${4:-}
  fleet_run_market_tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-market.XXXXXX") || exit 0
  trap 'rm -rf "$fleet_run_market_tmp"' EXIT
  # `<plugin>\t<inline marketplace>`, as the loop read them.
  printf '%s\n' "$fleet_run_market_fold" |
    jq -r '(.plugins // {}) | to_entries[] |
      [.key, (.value | if type == "object" then (.marketplace // "") else "" end)] |
      @tsv' >"$fleet_run_market_tmp/plugins"
  # The digests fleet_item_digest and the definition digest would print.
  {
    fleet_fold_item_values "$fleet_run_market_fold" | LC_ALL=C awk -F'\t' '$1 ~ /^plugins\./'
    fleet_definition_item_values "$fleet_run_market_defs" |
      LC_ALL=C awk -F'\t' '$1 ~ /^definitions\.plugins\./'
  } | fleet_value_digests >"$fleet_run_market_tmp/digests"
  # Every candidate item with its digest (empty when it has none), held or not.
  LC_ALL=C awk -F'\t' 'FILENAME == ARGV[1] { split($0, f, " "); d[f[1]] = f[2]; next }
    { print "plugins." $1 "\t" d["plugins." $1]
      print "definitions.plugins." $1 "\t" d["definitions.plugins." $1] }' \
    "$fleet_run_market_tmp/digests" "$fleet_run_market_tmp/plugins" |
    fleet_run_items_held "$fleet_run_market_holds" "$fleet_run_market_verdicts" \
      >"$fleet_run_market_tmp/held"
  while IFS='	' read -r fleet_run_market_plugin fleet_run_inline_market; do
    [ -n "$fleet_run_market_plugin" ] || continue
    ! grep -Fqx "plugins.$fleet_run_market_plugin" "$fleet_run_market_tmp/held" || continue
    fleet_run_market=$fleet_run_inline_market
    if [ -z "$fleet_run_market" ]; then
      fleet_run_market_definition=$(fleet_definition_entry "$fleet_run_market_defs" \
        plugins "$fleet_run_market_plugin")
      [ -n "$fleet_run_market_definition" ] || continue
      ! grep -Fqx "definitions.plugins.$fleet_run_market_plugin" \
        "$fleet_run_market_tmp/held" || continue
      fleet_run_market=$(fleet_resolve_surface "$fleet_run_market_defs" plugins \
        "$fleet_run_market_plugin" 2>/dev/null | jq -r '.marketplace // empty')
    fi
    [ -n "$fleet_run_market" ] || continue
    fleet_upstream_id_valid "$fleet_run_market" || continue
    printf '%s\n' "$fleet_run_market"
  done <"$fleet_run_market_tmp/plugins" |
    LC_ALL=C sort -u
)

fleet_run_node_unverified() {
  # `fleet_run_node_unverified LEDGER STORE HOST` — the one alert for a Node
  # switch left recorded in flight: the default is unverified and npm stays
  # off it. A condition (fleet_alert_lifecycle_rows): the end-of-pass sweep
  # clears it once a pass checks the runtime and the record is gone.
  fleet_alert_raise "$1" "$2" "$3" node-runtime-unverified node-runtime-unverified \
    "a Node runtime switch is recorded in flight and the old default could not be restored and verified; npm globals are skipped until it is" \
    runtimes.node || :
}

fleet_run_node_held() {
  # `fleet_run_node_held LEDGER STORE HOST ITEM` — a held `runtimes.node` is a
  # host quietly staying off Node releases (security patches included), so it
  # is alerted, not only printed. One kind and one slug, whatever the reason;
  # a condition the end-of-pass sweep clears once a pass converges it.
  fleet_alert_raise "$1" "$2" "$3" runtime-hold runtime-hold-runtimes-node \
    "runtimes.node is held on this host and its Node runtime is not converging; the run output names the reason" \
    "$4" || :
}

fleet_run_node_alert() {
  # `fleet_run_node_alert LEDGER STORE HOST STATUS ITEM` — the one mapping
  # from a Node convergence status to its alert, for the fast and full
  # cadences alike: 73 deferred and 75 held, 76 unverified default, anything
  # else none. The caller has already CHECKED both kinds for the item.
  case $4 in
    73 | 75) fleet_run_node_held "$1" "$2" "$3" "$5" ;;
    76) fleet_run_node_unverified "$1" "$2" "$3" ;;
  esac
}

fleet_run_full_node_runtime() (
  # `fleet_run_full_node_runtime STORE HOST FOLD DEFS HOLD_DIR` — the full
  # cadence's Node step. fnm never moves the default within a major on its
  # own, so this does, to the newest release in the declared major (or back
  # to the pinned version after a drift). A held or canary-waiting
  # `runtimes.node` is not touched, like every other maintenance action, but
  # a switch recorded in flight is always rolled back if it can be: that
  # only returns the host to its last verified state.
  node_full_store=$1
  node_full_host=$2
  # The pass's alert ledger (fleet_alert_checked), beside its holds.
  node_full_ledger=${5:+$5/alert-ledger}
  : "${node_full_ledger:=/dev/null}"
  node_full_runtime=$(printf '%s\n' "$3" | jq -c '(.runtimes // {}).node // empty')
  node_full_wanted=false
  # The apply loop's DEFERRAL of a backed-off switch (apply status 73,
  # fleet_run_apply_held) is not a refusal: this step is the retry it
  # promises, so only the other hold lines count here.
  node_full_holds=${5:+$5/sigholds}
  if [ -f "${node_full_holds:-}" ]; then
    { grep -Fvx 'runtimes.node apply status 73' "$5/sigholds" || :; } >"$5/sigholds.node"
    node_full_holds=$5/sigholds.node
  fi
  if [ -n "$node_full_runtime" ] &&
    [ "$(fleet_run_state_of "$node_full_runtime")" = enabled ] &&
    ! { [ -n "$5" ] &&
      fleet_run_item_is_held runtimes.node "" "$node_full_holds" "$5/verdicts"; }; then
    node_full_wanted=true
  fi
  if [ "$node_full_wanted" != true ]; then
    # Not converged here (held, waiting on its canary, or not desired), so
    # only the in-flight record is checked: its alert ends with the record.
    # A switch in progress elsewhere (74) is not checked at all.
    if [ -z "$(node_switch_marker_read)" ]; then
      fleet_alert_checked "$node_full_ledger" node-runtime-unverified runtimes.node
      exit 0
    fi
    node_full_status=0
    node_switch_recover || node_full_status=$?
    [ "$node_full_status" -eq 74 ] ||
      fleet_alert_checked "$node_full_ledger" node-runtime-unverified runtimes.node
    case $node_full_status in
      74) printf '  note  runtimes.node — a Node switch is in progress on this host; not touched this run\n' ;;
      75) printf '  note  runtimes.node — an interrupted switch was rolled back to its old default (verified)\n' ;;
      76) fleet_run_node_unverified "$node_full_ledger" "$node_full_store" "$node_full_host" ;;
    esac
    exit 0
  fi
  fleet_alert_checked "$node_full_ledger" runtime-hold runtimes.node
  fleet_alert_checked "$node_full_ledger" node-runtime-unverified runtimes.node
  node_full_status=0
  fleet_run_node_converge "$node_full_runtime" "$4" full </dev/null || node_full_status=$?
  fleet_run_node_alert "$node_full_ledger" "$node_full_store" "$node_full_host" \
    "$node_full_status" runtimes.node
  [ "$node_full_status" -ne 76 ] ||
    fleet_journal_append "$node_full_store" "$node_full_host" \
      "$(jq -cn --arg at "$(fleet_now)" \
        '{item:"runtimes.node",digest:"held",outcome:"held",at:$at}')" || :
  exit 0
)

fleet_run_full_pass() (
  # fleet_run_full_pass STORE HOST FOLD DEFS LAYERDIR TMP — everything the fast
  # run does NOT do, and the reason the fast interval can be 20 minutes:
  # discovery, upstreams, proposals, doctor and package updates run twice a
  # day, not 72 times.
  full_store=$1
  full_host=$2
  full_fold=$3
  full_defs=$4
  full_layers=$5
  full_hold_dir=${6:-}

  # §10.5: one file per host per upstream. No leases, no CAS, no TTLs, no
  # takeover — jitter is the coordination primitive. The run refreshes
  # plugin marketplaces BEFORE its item loop (fleet_plugins_refresh) and
  # stamps the pass; this is the refresh for a caller that did not.
  [ -e "${6:-}/plugins-refreshed" ] ||
    fleet_plugins_refresh "$full_store" "$full_host" "$full_fold" "$full_defs" \
      full "${6:-}" || :

  # §7.11.3's three aging policies, DELIBERATELY SEPARATE because they answer
  # different questions and have different natural periods. Both of the two that
  # ride a cadence ride THIS one; the third (history) stays instruction-driven,
  # because a re-root rewrites what every clone starts from.
  #
  # Pruning expired leaves is safe here and would not be in a snapshot model:
  # an old commit is verified against the roster at ITS parents, where the entry
  # still exists. Evidence retention carries no trust reasoning at all, because
  # evidence paths are never inputs to verification.
  fleet_trust_prune_expired "$full_store/$fleet_trust_roster_file" || :
  # The retention window has a floor: fleet_records_retention_days.
  fleet_records_age "$full_store" "$full_host" \
    "$(fleet_records_retention_days "$full_fold")" || :

  # §7.3a B's enrolled side: joins/ is read as a hint and NEVER trusted — the
  # address is SSH'd and the same pubkey confirmed on that machine before any
  # roster line is written.
  fleet_enroll_process_joins "$full_store" "$full_host" || :

  # §10.2: re-seed (upsert, never remove) and then look for unanimity. Seeding
  # writes into the WORKING COPY, never into the exported reviewed tree — the
  # export is a read of a commit and nothing may write back through it.
  fleet_seed_command || :
  fleet_run_proposals "$full_store" "$full_host" "$full_layers" "$6" || :

  # The Node runtime BEFORE the package pass (fleet_run_full_node_runtime).
  # A switch recorded in flight afterwards keeps the npm part of the pass off
  # the runtime: npm would resolve to a default nobody verified. Brew, winget
  # and the rest of the cadence still run, and an ordinary hold (the default
  # untouched or restored) skips nothing.
  fleet_run_full_node_runtime "$full_store" "$full_host" "$full_fold" "$full_defs" "$full_hold_dir"
  full_npm_blocked=false
  [ -z "$(node_switch_marker_read)" ] || full_npm_blocked=true
  [ "$full_npm_blocked" != true ] ||
    printf '  hold  packages (npm) — Node default is unverified after a failed runtime switch; npm globals skipped this pass\n'

  # The fleet-update contract, as a predicate: an unpinned package is kept
  # current by this pass — that is what anyone gets by doing nothing — and a
  # `version:` key opts one package out. Skipping the pinned ones is not an
  # optimisation; running them would quietly undo the pin.
  # The privilege-lane alert is a keyed condition: say the pass looked, so an
  # alert raised earlier clears on the first pass after the approval even
  # when no apt package remains to route.
  [ -z "$full_hold_dir" ] || fleet_alert_checked "$full_hold_dir/alert-ledger" privilege-lane '*'
  full_npm_queried=false
  full_npm_outdated='{}'
  # The per-package questions — held?, pinned?, how does it resolve? — asked
  # for the whole list at once, each by the predicate the loop used, and the
  # Homebrew upgrades gathered into one `brew upgrade` (below).
  full_managers=$(fleet_run_package_managers "$full_fold" "$full_host")
  full_pkg_tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-packages.XXXXXX") || exit 0
  printf '%s\n' "$full_fold" | jq -r '(.packages // {}) | keys[]' >"$full_pkg_tmp/names"
  : >"$full_pkg_tmp/held"
  if [ -n "$full_hold_dir" ]; then
    # fleet_run_item_is_held with no digest: a hold line or a `held` verdict
    # for the package or for its definition.
    awk '$0 != "" { print "packages." $0 "\t"; print "definitions.packages." $0 "\t" }' \
      "$full_pkg_tmp/names" |
      fleet_run_items_held "$full_hold_dir/sigholds" "$full_hold_dir/verdicts" \
        >"$full_pkg_tmp/held"
  fi
  fleet_packages_pinned "$full_defs" <"$full_pkg_tmp/names" >"$full_pkg_tmp/pinned" ||
    : >"$full_pkg_tmp/pinned"
  fleet_resolve_packages "$full_defs" "$full_managers" <"$full_pkg_tmp/names" \
    >"$full_pkg_tmp/resolved" 2>/dev/null || : >"$full_pkg_tmp/resolved"
  : >"$full_pkg_tmp/brew"
  # Read on fd 9: the body runs package managers, and a greedy one must not
  # eat the rest of the list.
  while IFS= read -r full_package <&9; do
      [ -n "$full_package" ] || continue
      ! grep -Fqx -e "packages.$full_package" -e "definitions.packages.$full_package" \
        "$full_pkg_tmp/held" || continue
      ! grep -Fqx -- "$full_package" "$full_pkg_tmp/pinned" || continue
      full_resolved=$(LC_ALL=C awk -F'\t' -v n="$full_package" \
        '$1 == n { print substr($0, length($1) + 2); exit }' "$full_pkg_tmp/resolved")
      if [ -z "$full_resolved" ]; then
        # shellcheck disable=SC2086 # the host's package_managers, in order
        full_resolved=$(fleet_resolve_package "$full_defs" "$full_package" \
          $full_managers) || :
      fi
      # `.resolved`, `.manager` and `.name`, each as `jq -r` printed it alone.
      full_fields=$(printf '%s\n' "$full_resolved" | jq -r '[.resolved, .manager, .name] |
        map(if type == "string" then . else tojson end) | join("\u001f")') ||
        full_fields=
      IFS=$fleet_run_sep read -r full_ok full_manager full_name <<EOF
$full_fields
EOF
      [ "$full_ok" = true ] || continue
      case $full_manager in
        homebrew | linuxbrew)
          printf '%s\n' "$full_name" >>"$full_pkg_tmp/brew"
          ;;
        winget) winget upgrade --id "$(printf '%s\n' "$full_resolved" | jq -r '.name')" \
          --silent --accept-package-agreements --accept-source-agreements >/dev/null 2>&1 </dev/null || : ;;
        scoop) scoop update "$(printf '%s\n' "$full_resolved" | jq -r '.name')" >/dev/null 2>&1 </dev/null || : ;;
        npm)
          # Never under a runtime a failed switch left unverified (above).
          [ "$full_npm_blocked" != true ] || continue
          # Upgrade only what the registry says is behind, to that exact
          # version: a blind `@latest` reinstall twice a day is churn, and a
          # package with its own updater (one that restarts a service, say)
          # must not be bounced on every cadence. `npm outdated` lists only
          # installed globals, so an absent package is left to the fast pass.
          full_npm_name=$(printf '%s\n' "$full_resolved" | jq -r '.name')
          if [ "$full_npm_queried" = false ]; then
            # A failed query still skips every npm global this pass (nothing
            # is known to be behind), but says so once rather than reading as
            # "all current".
            full_npm_outdated=$(npm_global_outdated 2>/dev/null) || {
              full_npm_outdated='{}'
              printf 'roundhouse: npm outdated query failed; npm globals are skipped this pass\n' >&2
            }
            full_npm_queried=true
          fi
          full_npm_latest=$(printf '%s\n' "$full_npm_outdated" |
            jq -r --arg name "$full_npm_name" '.[$name] // empty')
          npm_version_valid "$full_npm_latest" || continue
          if printf '%s\n' "$full_resolved" | jq -e '.attributes | has("update")' >/dev/null; then
            # The definition declared the package's own updater. Store
            # content is written by every synced host, so a definition alone
            # must never introduce a command: the updater runs only when THIS
            # host's own config.json declares the identical argv under
            # package_updaters, the same trust root the sealed lane uses.
            # Anything else holds the package, with no npm install fallback.
            full_npm_wanted=$(printf '%s\n' "$full_resolved" | jq -c '.attributes.update')
            full_npm_declared=$(jq -c --arg id "npm:$full_npm_name" \
              '(.package_updaters // {})[$id] // null' "$(config_path)" 2>/dev/null) ||
              full_npm_declared=null
            if [ "$full_npm_declared" != "$full_npm_wanted" ]; then
              printf '  hold  packages.%s — npm updater %s is not declared identically in this host'"'"'s package_updaters\n' \
                "$full_package" "$full_npm_wanted"
              continue
            fi
            # Exact argv, run by absolute path only once proven to be a bin
            # of the installed package (npm_global_run_updater).
            full_npm_update=()
            while IFS= read -r full_npm_update_arg; do
              full_npm_update+=("$full_npm_update_arg")
            done < <(printf '%s\n' "$full_resolved" | jq -r '.attributes.update[]')
            npm_global_run_updater "$full_npm_name" "${full_npm_update[@]}" >/dev/null 2>&1 || :
          else
            npm_global_install "$full_npm_name" "$full_npm_latest" || :
          fi
          [ "$(npm_global_installed_version "$full_npm_name")" = "$full_npm_latest" ] ||
            printf 'roundhouse: npm global %s did not reach %s\n' \
              "$full_npm_name" "$full_npm_latest" >&2
          ;;
        # Root work rides the local privilege lane once this host has had
        # its one approval; before it the package holds and the pass raises
        # the one-time-approval alert once. A scheduled run never prompts.
        apt) lane_fleet_run_apt "$full_store" "$full_host" "$full_package" \
          "$(printf '%s\n' "$full_resolved" | jq -r '.name')" "$full_hold_dir" || : ;;
        # A manager with no user-space update path is reported, never
        # silently skipped — the same answer fleet_install_package gives at
        # install time.
        *) printf '  hold  packages.%s — %s has no user-space update path\n' \
          "$full_package" "$full_manager" ;;
      esac
    done 9<"$full_pkg_tmp/names"
  # ONE `brew upgrade` for every resolved Homebrew package this host has
  # installed: brew upgrades the outdated ones and leaves the current ones, as
  # the per-package calls did, in one process and one auto-update. A name it
  # does not list as installed (an alias, a tap-qualified or a missing
  # formula) still gets its own call, so one unresolvable name cannot abort
  # the upgrade of the rest. Failures are ignored here exactly as they were.
  if [ -s "$full_pkg_tmp/brew" ] && command -v brew >/dev/null 2>&1; then
    { bounded_query brew list --formula -1 2>/dev/null; bounded_query brew list --cask -1 2>/dev/null; } </dev/null \
      >"$full_pkg_tmp/brew.installed" || :
    : >"$full_pkg_tmp/brew.batch"
    : >"$full_pkg_tmp/brew.single"
    LC_ALL=C awk -v batch="$full_pkg_tmp/brew.batch" -v single="$full_pkg_tmp/brew.single" '
      FILENAME == ARGV[1] { i[$0] = 1; next }
      !($0 in seen) { seen[$0] = 1; if ($0 in i) print > batch; else print > single }' \
      "$full_pkg_tmp/brew.installed" "$full_pkg_tmp/brew"
    if [ -s "$full_pkg_tmp/brew.batch" ]; then
      tr '\n' '\0' <"$full_pkg_tmp/brew.batch" |
        # One process for many upgrades, so twice one install's ceiling.
        run_bounded "$(($(run_bounded_seconds install) * 2))" \
          xargs -0 sh -c 'brew upgrade "$@" >/dev/null 2>&1 </dev/null' brew-upgrade || :
    fi
    while IFS= read -r full_brew_name; do
      [ -n "$full_brew_name" ] || continue
      bounded_verb brew upgrade "$full_brew_name" >/dev/null 2>&1 </dev/null || :
    done <"$full_pkg_tmp/brew.single"
  elif [ -s "$full_pkg_tmp/brew" ]; then
    # No brew to batch with: each call fails as it always did.
    while IFS= read -r full_brew_name; do
      bounded_verb brew upgrade "$full_brew_name" >/dev/null 2>&1 </dev/null || :
    done <"$full_pkg_tmp/brew"
  fi
  rm -rf "$full_pkg_tmp"

  # §10.7: the full cadence ends on the doctor's rows. Advisory by design — a
  # failing row reports, it does not abort a convergence that already happened.
  fleet_doctor_command || :
)

fleet_run_proposals() (
  # §10.2: where an item has an identical value in EVERY enrolled host file,
  # seeding proposes moving it up a layer. Unanimity is the bar — 3-of-5 is
  # normal curation for this fleet (141 vs 58 standalone skills is intent, not
  # drift) and produces no proposal and no alert.
  #
  # Each host's facts are folded once and every item is judged in one jq, the
  # per-item loop's questions over the same data: the item universe is the
  # sorted union of every host's items; a host whose fleet_item_value prints
  # nothing contributes no `{host, value}` (the loop's `--argjson` refused the
  # empty value, so it was skipped); fleet_proposal_unanimous's predicate
  # decides; and the proposals are written as fleet_proposal_write writes them,
  # through one batched record write.
  proposal_store=$1
  proposal_host=$2
  proposal_layers=$3
  proposal_tmp=$4
  proposal_evidence='identical in every enrolled host file'
  : >"$proposal_tmp/proposal-facts"
  while IFS= read -r proposal_peer; do
    [ -n "$proposal_peer" ] || continue
    jq -cn --arg host "$proposal_peer" --argjson facts \
      "$(fleet_host_facts "$proposal_layers" "$proposal_peer" 2>/dev/null || printf null)" \
      '{host: $host, facts: $facts}' 2>/dev/null ||
      jq -cn --arg host "$proposal_peer" '{host: $host, facts: null}'
  done <"$proposal_tmp/hosts" >"$proposal_tmp/proposal-facts"
  fleet_replicated_text_ok "$proposal_evidence" || return 0
  jq -s -r --arg facts_keys "$(fleet_host_fact_keys)" --arg us "$fleet_run_sep" \
    --arg store "$proposal_store" --arg by "$proposal_host" \
    --arg evidence "$proposal_evidence" --arg at "$(fleet_now)" \
    "$fleet_item_value_jq"'
    ($facts_keys | split("\n") | map(select(. != ""))) as $fk |
    def items_of: if type == "object" then
        to_entries[] | select(.value | type == "object") |
        select(.key as $k | $fk | index($k) | not) |
        .key as $c | .value | keys_unsorted[] | "\($c).\(.)"
      else empty end;
    . as $hosts |
    [$hosts[] | .facts | items_of] | unique[] as $item |
    # §8.2 P0: agent items are not promoted. Unanimity across machine
    # snapshots is how a plugin every host happened to have installed became
    # a fleet-wide want that no removal on any one host could undo.
    select(($item | startswith("plugins.") or startswith("skills.")) | not) |
    [$hosts[] | .host as $h |
      (.facts | if type == "object" then . else null end) as $f |
      [$item | fleet_item_value($f)] as $v |
      ($v | if length > 0 then {host: $h, value: .[0]} else empty end)] as $values |
    select(($values | length) > 1 and all($values[]; .value != null) and
      ([$values[].value] | unique | length) == 1) |
    ($item | gsub("[./]"; "-")) as $slug |
    "\($store)/proposals/promote-\($slug)-to-fleet.yaml\($us)\({proposes: "move",
      item: $item, value: $values[0].value, from: [$values[].host], to: "fleet.yaml",
      evidence: $evidence, by: $by, at: $at} | tojson)"' \
    <"$proposal_tmp/proposal-facts" 2>/dev/null | fleet_run_records_batch
)

fleet_seed_inventory_timeouts() {
  # `fleet_seed_inventory_timeouts STORE HOST SNAPSHOT` — one keyed
  # `inventory-timeout` alert per manager whose query the collector had to
  # stop (`manager_query_timeout`, collect-posix), and the clear of every one
  # whose manager answered this time. That manager's inventory is UNKNOWN for
  # the pass: the collector reported it unavailable, so nothing is seeded from
  # it, and the rest of the pass goes on. Store-scoped condition alerts, so
  # this check is the only thing that raises or clears them.
  seed_timeout_list=$(jq -r '
    select(any(.errors[]?; .code == "manager_query_timeout")) |
    ((if .kind == "error" then .id else .kind + ":" + .id end) |
      gsub("[^A-Za-z0-9._~-]+"; "-") | .[0:80]) as $slug |
    [$slug, ([.errors[] | select(.code == "manager_query_timeout") | .message][0])] |
    @tsv' "$3") || return 1
  printf '%s\n' "$seed_timeout_list" | while IFS='	' read -r seed_timeout_slug seed_timeout_message; do
    [ -n "$seed_timeout_slug" ] || continue
    fleet_alert_set "$1" "$2" inventory-timeout "$seed_timeout_slug" true \
      "$seed_timeout_message; this manager's inventory is unknown for the pass and nothing was taken from it" ||
      :
  done
  for seed_timeout_file in "$1/alerts/$2"/inventory-timeout--*.yaml; do
    [ -f "$seed_timeout_file" ] || continue
    seed_timeout_slug=${seed_timeout_file##*/inventory-timeout--}
    seed_timeout_slug=${seed_timeout_slug%.yaml}
    printf '%s\n' "$seed_timeout_list" | cut -f1 | grep -Fqx -- "$seed_timeout_slug" && continue
    fleet_alert_set "$1" "$2" inventory-timeout "$seed_timeout_slug" false '' || :
  done
}

fleet_seed_command() (
  # `roundhouse fleet-seed` — §10.2/§12. Discovery writes this host's OWN
  # `hosts/<name>.yaml` and `applied/<host>.yaml` to match what is installed —
  # for PACKAGES, so the first convergence after seeding is a no-op for them
  # BY CONSTRUCTION. That is the safety property worth paying for: a seeding
  # pass that treated the larger host as truth would install 83 packages
  # someone deliberately kept off a machine, and the reverse mistake deletes 83.
  #
  # Agent items (`plugins`, `skills`) are NOT seeded (§8.2 P0): a newly seeded
  # host therefore ADOPTS the fleet's plugins and skills on its first run —
  # reviewed and applied like any change — rather than snapshotting its own
  # into its host layer, where they overrode every change made anywhere else.
  #
  # It writes into the WORKING COPY and stops — no describe, no bookmark move,
  # no push. The next run's promote gate parses what it wrote and publishes it
  # through the ordinary gates (§6 step 4), which is what keeps seeding from
  # being a second, unreviewed path onto `main`. §12's sequence is exactly
  # this: fleet-init, fleet-enroll, fleet-seed, hand-edit fleet.yaml,
  # fleet-doctor.
  #
  # Re-seeding UPSERTS and never removes: a package uninstalled between seeds
  # is a convergence decision for the run to report by name, not something
  # seeding silently drops.
  fleet_run_env
  require_jq
  require_yq
  seed_store=$(fleet_store_path)
  seed_host=$(fleet_host_name)
  seed_tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-seed.XXXXXX")
  trap 'rm -rf "$seed_tmp"' EXIT HUP INT TERM

  # A TEST hook may substitute the snapshot. It decides what gets DESCRIBED,
  # never what is trusted, and a fixture that shells out to the real collector
  # is a fixture that passes for the wrong reason on the next runner image.
  if fleet_test_hook "${ROUNDHOUSE_SEED_SNAPSHOT:-}"; then
    cat "$ROUNDHOUSE_SEED_SNAPSHOT" >"$seed_tmp/snapshot.jsonl"
  else
    # A partial collection (exit 2: some manager could not be read) still
    # reports which managers timed out, and then fails exactly as it did
    # before: it stops a seed run by hand, and the full pass, which runs the
    # seed without errexit, carries on with what was read.
    seed_collect_rc=0
    collect_command --section agents --section packages \
      --output "$seed_tmp/snapshot.jsonl" >/dev/null || {
      seed_collect_rc=$?
      [ ! -f "$seed_tmp/snapshot.jsonl" ] ||
        fleet_seed_inventory_timeouts "$seed_store" "$seed_host" "$seed_tmp/snapshot.jsonl" || :
      (exit "$seed_collect_rc")
    }
    [ "$seed_collect_rc" != 0 ] ||
      fleet_seed_inventory_timeouts "$seed_store" "$seed_host" "$seed_tmp/snapshot.jsonl" || :
  fi

  # ponytail: plugins, standalone skills and packages — the three surfaces the
  # shipped collector observes. `agents`, `mcp_servers` and `hooks` have no
  # observed-state side at all (declared boundary B-3), so seeding them would
  # be inventing state rather than reading it.
  # The plugins apply surface is Claude-owned. Codex rows share plugin names
  # but can name a different marketplace or state; reducing both harnesses
  # into this map would overwrite Claude's record and ask its manager to
  # install Codex-only plugins. Unknown ownership cannot prove a Claude want.
  seed_desired=$(jq -sc '
    # `.enabled // true` would read FALSE as absent — jq'\''s alternative operator
    # treats false and null alike, and a disabled plugin would seed as enabled.
    def state($e): if $e.data.enabled == false then "disabled" else "enabled" end;
    reduce (.[] | select(.status == "present")) as $r ({};
      if $r.kind == "plugin" and $r.data.agent == "claude" then
        .plugins[$r.data.name] = (if ($r.data.marketplace // "") == "" then state($r)
          else {state: state($r), marketplace: $r.data.marketplace} end)
      elif $r.kind == "skill" then .skills[$r.data.name] = "enabled"
      # The fnm runtime record (`fnm:node`) is a package record only so the
      # sealed updates lane can carry a switch. It is never a package: seeding
      # it would manufacture `packages.node`, which Homebrew resolves to its
      # own `node` formula. `runtimes.node` is not seeded either; the store
      # gains `runtimes:` by hand, once every host understands the category.
      # An npm global is not seeded either: npm manages a package only through
      # a definition with an `npm:` entry, which seeding cannot author, so a
      # seeded `packages.<npm name>` would resolve to a system manager and
      # own the global without ever carrying it across a Node switch.
      elif $r.kind == "package" and
        (((($r.id // "") | startswith("fnm:") or startswith("npm:")) or
          $r.data.manager == "fnm" or $r.data.manager == "npm") | not) then
        .packages[$r.data.name] = "enabled"
      else . end)' "$seed_tmp/snapshot.jsonl")
  # §3.1/§8.2 P0: RE-SEED NO LONGER WRITES THE AGENT KEYS. A seed snapshots
  # whatever this machine has installed into its own host layer, the narrowest
  # one, so every re-seed re-added a plugin the fleet had retired and
  # overrode every change made anywhere else. `plugins` and `skills` are
  # dropped here, after the reducer, and nothing else is: packages and the
  # host facts below seed exactly as before, and an agent entry already in the
  # host file is left alone (re-seed upserts, it never removes).
  seed_desired=$(printf '%s\n' "$seed_desired" | jq -c 'del(.plugins, .skills)')

  # MACHINE TRUTH, seeded from the one file that already states it. `platform`
  # and `groups` are host FACTS rather than desired items — the fold reads them
  # to pick the `os/` and `groups/` layers, and `machine-truth` reports a host
  # file without them as incomplete. Seeding captured the three observed
  # surfaces and not these, so every enrolled host needed a hand-authored
  # hosts/<name>.yaml before its own layers resolved. config.json already
  # carries both, validated (platform is one of macos/linux/wsl/windows and
  # every group matches the name charset), so there is nothing to infer.
  #
  # `package_managers` is the same kind of fact: the apply path and the update
  # pass read the host's list from the fold to resolve every package. Seeding
  # without it left the list empty, so the resolver tried no manager and held
  # every enabled package as "no package manager on this host can provide" —
  # on hosts whose manager plainly provides it.
  #
  # Unlike platform and groups it is REFRESHED, not just seeded: config.json
  # owns the list (it is where an operator adds `npm`, and what the collector
  # reads), so when config states one it replaces the host file's list whole
  # and in config order; when config states none (or null), the stored list
  # stays. Under "the host file wins" the first seed froze it and later config
  # edits never reached the store. An unchanged list rewrites identical bytes.
  #
  # PRESENCE, not truthiness: a machine legitimately in no groups carries
  # `groups: []`, and dropping an empty list is not the same as having no
  # opinion. The `machine-truth` doctor row compares `.groups // null` on both
  # sides, and jq's `//` passes `[]` through — so an omitted field reads as
  # `null` against the config's `[]` and the row fires forever on a host that
  # is correctly configured.
  seed_facts=$(jq -c --arg host "$seed_host" '
    (.machines[$host] // {}) |
    {} + (if has("platform") then {platform: .platform} else {} end)
       + (if has("groups") then {groups: .groups} else {} end)
       + (if has("package_managers") then {package_managers: .package_managers} else {} end)
    ' "$(config_path)" 2>/dev/null) || seed_facts='{}'
  [ -n "$seed_facts" ] || seed_facts='{}'

  seed_file="$seed_store/hosts/$seed_host.yaml"
  mkdir -p "$(dirname "$seed_file")"
  seed_existing=$(fleet_record_read "$seed_file" '{}')
  # Facts are the BASE, not an override: a value already in the host file wins,
  # because someone wrote it deliberately and seeding is not a place to
  # relitigate it. Observed surfaces still win over both, unchanged. The one
  # exception is the refreshed `package_managers` above, which config.json owns.
  seed_pm_before=$(printf '%s\n' "$seed_existing" | jq -c '.package_managers // null')
  seed_pm_after=$(printf '%s\n' "$seed_facts" | jq -c '.package_managers // null')
  # The write stays a plain statement so a direct `fleet-seed` (set -e) still
  # stops on a failed write, exactly as before; the status only gates the notice.
  fleet_record_write "$seed_file" \
    "$(printf '%s\n' "$seed_existing" | jq -c --argjson seeded "$seed_desired" \
      --argjson facts "$seed_facts" '($facts * . * $seeded) +
        ($facts | with_entries(select(.key == "package_managers" and .value != null)))')"
  seed_write_status=$?

  seed_fold=$(fleet_fold "$seed_store" "$seed_host")
  # Say so when the refresh changed the list: dropping a manager holds every
  # package only it provides, and the doctor does not compare this fact. A
  # later split file (hosts/<name>/*.yaml) that states the list folds after
  # this file and still wins, so check the EFFECTIVE value and say so instead
  # of claiming a refresh that did not take.
  seed_pm_effective=$(printf '%s\n' "$seed_fold" | jq -c '.package_managers // null' 2>/dev/null)
  if [ "$seed_write_status" -ne 0 ] || [ "$seed_pm_after" = null ]; then
    :
  elif [ -n "$seed_pm_effective" ] && [ "$seed_pm_effective" != "$seed_pm_after" ]; then
    printf 'roundhouse: package_managers for %s from config.json (%s) does not reach the fold (overridden by another layer, e.g. hosts/%s/*.yaml); the effective list is %s\n' \
      "$seed_host" "$seed_pm_after" "$seed_host" "$seed_pm_effective" >&2
  elif [ "$seed_pm_before" != null ] && [ "$seed_pm_after" != "$seed_pm_before" ]; then
    printf 'roundhouse: package_managers for %s refreshed from config.json: %s -> %s\n' \
      "$seed_host" "$seed_pm_before" "$seed_pm_after"
  fi

  # Every seeded item's digest at once (fleet_value_digests over the values
  # fleet_item_digest would hash), then ONE read-modify-write of
  # applied/<host>.yaml carrying them in the seeded order — the record a
  # fleet_applied_record per item produced, without re-reading and
  # re-writing the whole file once per item.
  fleet_items "$seed_desired" >"$seed_tmp/items"
  fleet_fold_item_values "$seed_fold" >"$seed_tmp/values"
  # In the seeded order, so a newly owned item lands where the per-item
  # writes would have appended it.
  LC_ALL=C awk -F'\t' 'FILENAME == ARGV[1] { if (!($1 in v)) v[$1] = $0; next }
    ($0 in v) { print v[$0] }' \
    "$seed_tmp/values" "$seed_tmp/items" | fleet_value_digests >"$seed_tmp/digests"
  if [ -s "$seed_tmp/digests" ]; then
    seed_applied=$(fleet_applied_path "$seed_store" "$seed_host")
    seed_record=$(fleet_record_read "$seed_applied" '{}' |
      jq -c --rawfile digests "$seed_tmp/digests" --arg at "$(fleet_now)" '
        reduce ($digests | split("\n")[] | select(length > 65) |
          [.[:-65], .[-64:]]) as $e (.;
          .items[$e[0]] = {digest: $e[1], at: $at})')
    fleet_record_write "$seed_applied" "$seed_record"
  fi

  printf 'roundhouse: seeded %s items into %s and applied/%s.yaml (working copy only — the next run publishes them)\n' \
    "$(fleet_items "$seed_desired" | grep -c . || printf 0)" \
    "${seed_file#"$seed_store/"}" "$seed_host"
)

fleet_adopt_pin_command() (
  # `roundhouse fleet-adopt-pin PLUGIN PIN.json` — §10.6's self-update
  # containment. The CONTAINMENT carries verbatim: roundhouse updating itself
  # is gated separately from ordinary convergence, because the code that
  # decides whether an update is safe is the code being updated.
  #
  # The RECORD is re-implemented. v1 emitted `schema:"roundhouse.sync-adopt-pin",
  # schema_version:1` and §14 bans both keys; the decision is now an ordinary
  # item under the closed category set — `plugins.<name>`, the same id, digest
  # and shape every other item carries, so nothing has to learn a second
  # vocabulary to read it.
  fleet_run_env
  require_jq
  adopt_plugin=$1
  adopt_file=$2
  [ -f "$adopt_file" ] || {
    printf 'roundhouse: no pin file at %s\n' "$adopt_file" >&2
    exit 66
  }
  adopt_store=$(fleet_store_path)
  adopt_sha=$(jq -r '.sha // empty' "$adopt_file")
  adopt_version=$(jq -r '.version // empty' "$adopt_file")
  adopt_by=$(jq -r '.updated_by // empty' "$adopt_file")
  adopt=false
  adopt_reason="no host has published an applied record for plugins.$adopt_plugin at this pin"
  if [ "$adopt_plugin" != roundhouse ]; then
    # Only roundhouse is contained: every other plugin rides the ordinary
    # review, canary and apply gates, and a second gate in front of them would
    # be a second policy to keep in step with the first.
    adopt=true
    adopt_reason='an ordinary plugin adopts through the ordinary gates'
  elif [ "$adopt_version" = "$(jq -r '.version' \
    "$plugin_root/.codex-plugin/plugin.json" 2>/dev/null)" ]; then
    adopt=true
    adopt_reason='the pin names the version already running here'
  elif [ -n "$adopt_by" ] &&
    [ "$(fleet_applied_digest "$adopt_store" "$adopt_by" "plugins.$adopt_plugin")" = \
      "$adopt_sha" ]; then
    # The containment condition, read off the ONE record that answers it:
    # applied/<updating-host>.yaml says that host is carrying this pin RIGHT
    # NOW, and §7.3 says only that host could have written it. A journal replay
    # would answer the same question more slowly and with more ways to be wrong.
    adopt=true
    adopt_reason="$adopt_by has this pin applied"
  fi
  jq -n --arg item "plugins.$adopt_plugin" --arg digest "$adopt_sha" \
    --arg version "$adopt_version" --arg by "$adopt_by" \
    --argjson adopted "$adopt" --arg reason "$adopt_reason" \
    --arg at "$(fleet_now)" \
    '{item:$item, digest:(if $digest == "" then null else $digest end),
      version:(if $version == "" then null else $version end),
      updated_by:(if $by == "" then null else $by end),
      adopted:$adopted, reason:$reason, at:$at}'
  [ "$adopt" = true ] || exit 65
)

fleet_rollback_command() (
  # `roundhouse fleet-rollback ITEM [--now]` — §10.8. Rollback is NOT a special
  # path: a fleet-wide rollback is a signed revert commit on `main` that flows
  # through the exact same review, canary and apply gates as any other change.
  # That is why it can be trusted — there is no privileged "undo" code path
  # that has never been exercised.
  fleet_run_env
  require_jq
  require_yq
  rollback_now=false
  rollback_item=
  while [ $# -gt 0 ]; do
    case $1 in
      --now) rollback_now=true ;;
      -*)
        printf 'roundhouse: unknown fleet-rollback option: %s\n' "$1" >&2
        exit 64
        ;;
      *) rollback_item=$1 ;;
    esac
    shift
  done
  [ -n "$rollback_item" ] || {
    printf 'roundhouse: fleet-rollback needs an item id\n' >&2
    exit 64
  }
  rollback_store=$(fleet_store_path)
  rollback_host=$(fleet_host_name)
  fleet_vcs_store_ready "$rollback_store" || exit $?
  [ "$(fleet_vcs_heads_local "$rollback_store" | grep -c .)" -eq 1 ] || {
    printf 'roundhouse: main is diverged; reconcile before rolling back (§8.2)\n' >&2
    exit 65
  }
  rollback_ref=$(fleet_vcs_heads_local "$rollback_store" | head -1)
  rollback_tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-rollback.XXXXXX")
  trap 'rm -rf "$rollback_tmp"' EXIT HUP INT TERM
  fleet_run_export "$rollback_store" "$rollback_ref" "$rollback_tmp/now"
  rollback_path=$(fleet_run_item_layer "$rollback_tmp/now" "$rollback_host" \
    "$rollback_item") || {
    printf 'roundhouse: no layer carries %s at the reviewed ref\n' "$rollback_item" >&2
    exit 65
  }

  # The change that last touched the layer file this item resolves from. A
  # `files()` revset, never a description grep: the trailer is self-asserted
  # and a commit that merely claims to have set an item is not evidence.
  rollback_bad=$(jj -R "$rollback_store" log \
    -r "::$rollback_ref & files(root:\"$rollback_path\")" \
    --no-graph -T 'commit_id ++ "\n"' | head -1)
  [ -n "$rollback_bad" ] || {
    printf 'roundhouse: nothing in history touched %s\n' "$rollback_path" >&2
    exit 65
  }
  rollback_change=$(jj -R "$rollback_store" log -r "$rollback_bad" --no-graph \
    -T 'change_id')

  rollback_before=$(jj -R "$rollback_store" log -r "children($rollback_ref)" \
    --no-graph -T 'commit_id ++ "\n"')
  jj -R "$rollback_store" revert -r "$rollback_bad" -d "$rollback_ref" >/dev/null
  rollback_revert=$(jj -R "$rollback_store" log -r "children($rollback_ref)" \
    --no-graph -T 'commit_id ++ "\n"' |
    grep -vxF "$(printf '%s\n' "$rollback_before")" | head -1)
  [ -n "$rollback_revert" ] || {
    printf 'roundhouse: jj revert produced no new commit\n' >&2
    exit 65
  }
  # `jj revert` reverses the WHOLE commit, and a run commit bundles the layer
  # edit with that run's journal, applied/ and alert records (§6 step 6 writes
  # them into the same @). Reversing those would delete evidence peers have
  # already seen and make this host disown what it installed — §10.3's "never
  # prune" and §10.1's canary attribution both rest on those files. So the
  # records are restored to their pre-revert content and only the LAYERS roll
  # back, which is what §10.8 means by a revert of the change.
  rollback_revert_change=$(jj -R "$rollback_store" log -r "$rollback_revert" \
    --no-graph -T 'change_id')
  jj -R "$rollback_store" restore --from "$rollback_ref" --into "$rollback_revert" \
    'root:journal' 'root:applied' 'root:alerts' 'root:findings' \
    'root:upstreams' 'root:proposals' 'root:lineage' >/dev/null 2>&1 || :
  # `jj restore --into` rewrites the commit, so its commit id moved. The CHANGE
  # id did not — which is the property §7.4 records and the one thing that
  # makes a rewritten commit findable again.
  rollback_revert=$(jj -R "$rollback_store" log -r "$rollback_revert_change" \
    --no-graph -T 'commit_id')
  jj -R "$rollback_store" describe -r "$rollback_revert" \
    -m "revert $rollback_item

$(fleet_vcs_trailers "$rollback_host" revert \
      "rollback; $rollback_item reverted on $rollback_host" \
      "$rollback_item" "$rollback_change")" >/dev/null
  # Every rewrite moves the commit id and preserves the change id, so the
  # bookmark is set from the change and not from a stale id — pointing `main`
  # at the pre-describe commit would publish a revert with no trailers at all.
  rollback_revert=$(jj -R "$rollback_store" log -r "$rollback_revert_change" \
    --no-graph -T 'commit_id')

  # The reverted value, read from the revert commit itself.
  fleet_run_export "$rollback_store" "$rollback_revert" "$rollback_tmp/after"
  rollback_digest=$(fleet_item_digest \
    "$(fleet_fold "$rollback_tmp/after" "$rollback_host")" "$rollback_item") ||
    rollback_digest=absent

  if [ "$rollback_now" = true ]; then
    # THE ONLY CANARY BYPASS IN THE DESIGN, and it is bound rather than being a
    # flag that turns a gate off. Two independent checks, both of them about
    # HISTORY and neither about the trailer's claim, and BOTH BEFORE the
    # bookmark moves — a refusal that had already advanced `main` would publish
    # the very revert it refused to accelerate on the next ordinary run.
    #
    #   §8.2b rule 3's scoped check — the reverted value must equal what the
    #   named change replaced, and the value it displaces must equal what that
    #   change set. Checking only the first verifies the claim is true about
    #   history, not that it is about THIS item.
    #
    #   §10.8's revert-signature predicate — this host applied that digest
    #   before and later stopped. A forward change cannot satisfy it.
    fleet_run_export "$rollback_store" "$rollback_bad-" "$rollback_tmp/replaced"
    fleet_run_export "$rollback_store" "$rollback_bad" "$rollback_tmp/set"
    rollback_replaced=$(fleet_item_value \
      "$(fleet_fold "$rollback_tmp/replaced" "$rollback_host")" "$rollback_item")
    rollback_set=$(fleet_item_value \
      "$(fleet_fold "$rollback_tmp/set" "$rollback_host")" "$rollback_item")
    rollback_after=$(fleet_item_value \
      "$(fleet_fold "$rollback_tmp/after" "$rollback_host")" "$rollback_item")
    rollback_before_value=$(fleet_item_value \
      "$(fleet_fold "$rollback_tmp/now" "$rollback_host")" "$rollback_item")
    rollback_bound=true
    { [ -n "$rollback_replaced" ] && [ "$rollback_after" = "$rollback_replaced" ] &&
      [ "$rollback_before_value" = "$rollback_set" ]; } || {
      printf 'roundhouse: --now refused: %s is not a verified revert of %s (§8.2b rule 3)\n' \
        "$rollback_item" "$rollback_change" >&2
      rollback_bound=false
    }
    [ "$rollback_bound" != true ] ||
      fleet_run_is_revert "$rollback_store" "$rollback_host" "$rollback_item" \
        "$rollback_digest" || {
      printf 'roundhouse: --now refused: this host has no applied-then-withdrawn record for %s at %s (§10.8)\n' \
        "$rollback_item" "$rollback_digest" >&2
      rollback_bound=false
    }
    [ "$rollback_bound" = true ] || {
      jj -R "$rollback_store" abandon -r "$rollback_revert" >/dev/null 2>&1 || :
      exit 65
    }
  fi

  # §6 step 6's order, unchanged: the bookmark moves, the working copy lands on
  # the revert, the evidence is written INTO that working copy, and only then
  # does anything push. Journaling before `jj new` would write the record into
  # a commit the publish then walks away from.
  jj -R "$rollback_store" bookmark set main -r "$rollback_revert" >/dev/null
  jj -R "$rollback_store" new "$rollback_revert" >/dev/null

  if [ "$rollback_now" = true ]; then
    # Signed and journaled like everything else, so §7.3 attributes it to a
    # host and every peer sees it; doctor reports every override in the last 30
    # days. A bypass nobody counts is a bypass that becomes routine.
    fleet_journal_append "$rollback_store" "$rollback_host" \
      "$(jq -cn --arg item "$rollback_item" --arg d "$rollback_digest" \
        --arg at "$(fleet_now)" \
        '{item:$item,digest:$d,outcome:"applied",override:"canary",at:$at}')" || :
    fleet_alert_write "$rollback_store" "$rollback_host" canary-override \
      "canary-override-$(printf '%s' "$rollback_item" | tr './' '--')" \
      "canary wait bypassed for $rollback_item by an explicit --now" \
      "$rollback_item" || :
  else
    fleet_journal_append "$rollback_store" "$rollback_host" \
      "$(jq -cn --arg item "$rollback_item" --arg d "$rollback_digest" \
        --arg at "$(fleet_now)" \
        '{item:$item,digest:$d,outcome:"reverted",at:$at}')" || :
  fi

  fleet_run_publish "$rollback_store" "$rollback_host" revert \
    "rollback $rollback_item" "$rollback_item" || exit $?
  printf 'roundhouse: reverted %s (change %s); every host re-reviews it as the new change it is\n' \
    "$rollback_item" "$rollback_change"
  # §10.8's per-category honesty: a rollback that silently cannot roll
  # something back is worse than no rollback.
  case ${rollback_item%%.*} in
    projects)
      printf 'roundhouse: projects are NOT reversible by this system — reverting the entry stops managing the project, it does not restore repository state\n'
      ;;
    mcp_servers | hooks)
      printf 'roundhouse: %s is reversible for CONFIGURATION only — removing it stops it firing, it does not undo what it already did\n' \
        "${rollback_item%%.*}"
      ;;
  esac
)

# --- §7.6/§10.2/§10.4 the supervised verbs ------------------------------------
#
# Every command below writes into the WORKING COPY and stops. None of them
# describes, moves a bookmark or pushes: the next `fleet-run` parses what they
# wrote and publishes it through the ordinary gates (§6 step 4). That is what
# keeps the supervised surface from being a second, unreviewed path onto `main`
# — the same rule `fleet-seed` follows, for the same reason.

fleet_review_command() (
  # `roundhouse fleet-review ITEM pass|hold REASON` — §7.6. The verdict binds
  # to the digest the item resolves to RIGHT NOW; it is host-local and never
  # replicated, so it can never read as consent given on another host's behalf.
  fleet_run_env
  require_jq
  require_yq
  review_item=$1
  review_verdict=$2
  review_reason=$3
  # The item id names a FILE under store.run/verdicts/. The digest lookup below
  # already refuses anything that does not resolve in the fold, so this is the
  # second lock on the same door — but it is the one that is about the path.
  case $review_item in
    '' | */* | .*)
      printf 'roundhouse: %s is not an item id (<category>.<name>)\n' \
        "${review_item:-<empty>}" >&2
      exit 64
      ;;
  esac
  case $review_verdict in
    pass | hold) ;;
    *)
      printf 'roundhouse: fleet-review verdict must be pass or hold\n' >&2
      exit 64
      ;;
  esac
  [ -n "$review_reason" ] || {
    printf 'roundhouse: fleet-review requires a reason\n' >&2
    exit 64
  }
  review_store=$(fleet_store_path)
  review_host=$(fleet_host_name)
  review_digest=$(fleet_item_digest \
    "$(fleet_run_desired "$review_store" "$review_host")" "$review_item") || {
    printf 'roundhouse: no layer carries %s for %s\n' "$review_item" "$review_host" >&2
    exit 65
  }
  fleet_run_verdict_write "$review_item" "$review_digest" "$review_reason" \
    human "$review_verdict"
  # A host-local verdict is news nothing on the remote carries, so the poll
  # floor must not sit it out: the next pass acts on it.
  : >"$(fleet_run_state_dir)/retry-owed"
  printf 'roundhouse: %s %s at %s\n' "$review_item" "$review_verdict" "$review_digest"
)

fleet_apply_command() (
  # `roundhouse fleet-apply ITEM` — §6. THE VERDICT GATE IS THE POINT: an apply
  # with no recorded pass at this exact digest is refused, so this verb can
  # never become an unreviewed write path that happens to be shorter to type
  # than the reviewed one. A stale pass fails the same way an absent one does.
  fleet_run_env
  require_jq
  require_yq
  apply_item=$1
  apply_store=$(fleet_store_path)
  apply_host=$(fleet_host_name)
  apply_fold=$(fleet_run_desired "$apply_store" "$apply_host")
  apply_digest=$(fleet_item_digest "$apply_fold" "$apply_item") || {
    printf 'roundhouse: no layer carries %s for %s\n' "$apply_item" "$apply_host" >&2
    exit 65
  }
  [ "$(fleet_run_verdict_digest "$apply_item")" = "$apply_digest" ] || {
    printf 'roundhouse: no passing review of %s at %s; run `roundhouse fleet-review %s pass REASON` first\n' \
      "$apply_item" "$apply_digest" "$apply_item" >&2
    exit 65
  }
  apply_status=0
  apply_now=$(fleet_now)
  apply_value=$(fleet_item_value "$apply_fold" "$apply_item")
  case $apply_item in
    plugins.*)
      if [ "$(fleet_run_state_of "$apply_value")" = absent ]; then
        fleet_run_tombstone_converge "$apply_store" "$apply_host" \
          "$(fleet_definitions_load "$apply_store")" "$apply_item" "$apply_value" \
          "$apply_digest" "$apply_now" || apply_status=$?
        case $apply_status in
          0 | 70)
            printf 'roundhouse: %s converged to absent at %s (working copy only — the next run publishes it)\n' \
              "$apply_item" "$apply_digest"
            exit 0
            ;;
        esac
      fi
      ;;
  esac
  [ "$apply_status" -ne 0 ] ||
    fleet_run_apply_item "$apply_store" "$apply_host" \
      "$(fleet_definitions_load "$apply_store")" "$apply_item" "$apply_value" \
      "$(fleet_run_package_managers "$apply_fold" "$apply_host")" ||
    apply_status=$?
  case $apply_status in
    0)
      fleet_applied_record "$apply_store" "$apply_host" "$apply_item" \
        "$apply_digest" "$apply_now"
      fleet_journal_append "$apply_store" "$apply_host" \
        "$(jq -cn --arg item "$apply_item" --arg d "$apply_digest" \
          --arg at "$apply_now" \
          '{item:$item,digest:$d,outcome:"applied",at:$at}')" || :
      printf 'roundhouse: applied %s at %s (working copy only — the next run publishes it)\n' \
        "$apply_item" "$apply_digest"
      ;;
    70)
      # The same split the run makes, for the same reason — and here it also
      # stops the manual verb from WITHDRAWING evidence: a `held` record dated
      # after an earlier `applied`/`satisfied` fails canary condition 2 and
      # would silently re-block every downstream host.
      fleet_journal_append "$apply_store" "$apply_host" \
        "$(jq -cn --arg item "$apply_item" --arg d "$apply_digest" \
          --arg at "$apply_now" \
          '{item:$item,digest:$d,outcome:"satisfied",at:$at}')" || :
      printf 'roundhouse: %s is satisfied at %s — this design has no state-alignment verb for its category (working copy only)\n' \
        "$apply_item" "$apply_digest"
      ;;
    *)
      fleet_journal_append "$apply_store" "$apply_host" \
        "$(jq -cn --arg item "$apply_item" --arg d "$apply_digest" \
          --arg at "$apply_now" \
          '{item:$item,digest:$d,outcome:"held",at:$at}')" || :
      printf 'roundhouse: this host could not apply %s, or a gate refused it\n' \
        "$apply_item" >&2
      # 74 is the run loop's retry hint; this verb reports any hold as 75.
      [ "$apply_status" -ne 74 ] || apply_status=75
      exit "$apply_status"
      ;;
  esac
)

fleet_accept_command() (
  # `roundhouse fleet-accept SLUG` — §10.2. A proposal is a suggestion with no
  # authority; accepting it is TWO ORDINARY EDITS this verb makes for you —
  # write the value at the proposed layer, drop it from each host file that
  # carried it — and nothing else. The item's digest is unchanged by
  # construction, so no host re-reviews anything: promotion moves WHERE a value
  # is written, never WHAT it is.
  fleet_run_env
  require_jq
  require_yq
  accept_slug=$1
  case $accept_slug in
    '' | */* | .*)
      printf 'roundhouse: invalid proposal slug: %s\n' "${accept_slug:-<empty>}" >&2
      exit 64
      ;;
  esac
  accept_store=$(fleet_store_path)
  accept_file="$accept_store/proposals/$accept_slug.yaml"
  [ -f "$accept_file" ] || {
    printf 'roundhouse: no proposal at proposals/%s.yaml\n' "$accept_slug" >&2
    exit 66
  }
  accept=$(fleet_record_read "$accept_file" '{}')
  accept_item=$(printf '%s\n' "$accept" | jq -r '.item // empty')
  accept_to=$(printf '%s\n' "$accept" | jq -r '.to // empty')
  accept_value=$(printf '%s\n' "$accept" | jq -c '.value')
  [ -n "$accept_item" ] && [ -n "$accept_to" ] || {
    printf 'roundhouse: proposal %s names no item or no target layer\n' "$accept_slug" >&2
    exit 65
  }
  # The target is store content, and it reaches a file path. It passes the same
  # layer-path predicate the fold uses, so a proposal cannot name `../../.ssh`
  # or a records directory and have this verb write there.
  fleet_run_layer_path "$accept_to" || {
    printf 'roundhouse: proposal %s targets %s, which is not a layer file\n' \
      "$accept_slug" "$accept_to" >&2
    exit 65
  }
  accept_split=$(fleet_item_split "$accept_item") || {
    printf 'roundhouse: proposal %s names an unsplittable item: %s\n' \
      "$accept_slug" "$accept_item" >&2
    exit 65
  }
  accept_category=$(printf '%s\n' "$accept_split" | sed -n 1p)
  accept_name=$(printf '%s\n' "$accept_split" | sed -n 2p)
  fleet_record_write "$accept_store/$accept_to" \
    "$(fleet_record_read "$accept_store/$accept_to" '{}' |
      jq -c --arg c "$accept_category" --arg n "$accept_name" \
        --argjson v "$accept_value" 'setpath([$c, $n]; $v)')"
  printf '%s\n' "$accept" | jq -r '(.from // [])[]' |
    while IFS= read -r accept_from; do
      [ -n "$accept_from" ] || continue
      # `from[]` is store content reaching a WRITE path, exactly as `to` is —
      # and only `to` was validated. `from: ["../../../.ssh/config"]` resolves
      # outside the store, and the `-f` test below only limits it to
      # overwriting an existing file with YAML.
      fleet_host_name_ok "$accept_from" || {
        printf 'roundhouse: proposal %s names an unusable host in from[]: %s\n' \
          "$accept_slug" "$accept_from" >&2
        continue
      }
      accept_host_file="$accept_store/hosts/$accept_from.yaml"
      [ -f "$accept_host_file" ] || continue
      fleet_record_write "$accept_host_file" \
        "$(fleet_record_read "$accept_host_file" '{}' |
          jq -c --arg c "$accept_category" --arg n "$accept_name" \
            'delpaths([[$c, $n]])')"
    done
  # Acted on, so it goes. Leaving it would re-offer a promotion that has
  # already happened, and the next full pass re-proposes on its own if the
  # unanimity that produced it is somehow still true.
  rm -f "$accept_file"
  printf 'roundhouse: %s now lives in %s (working copy only — the next run publishes it)\n' \
    "$accept_item" "$accept_to"
)

fleet_lock_command() (
  # The run-lock, taken by hand: one runner per host per store. A second run
  # exits 75 and STOPS rather than forcing — two convergences racing one plugin
  # cache is the failure this prevents.
  #
  # The lock is marked `manual`: it outlives this command by design, and no
  # process stands for the operator holding it, so it is never judged dead and
  # taken over. It is NEVER released automatically either: a forgotten hand
  # lock makes every run exit 0 ("another run holds") until it passes the
  # stale age, and exit 75 (the stale refusal) from then on, until
  # `fleet-unlock` releases it.
  require_jq
  lock=$(fleet_lock_path)
  fleet_lock_acquire "$lock" "$PPID" manual || {
    printf 'roundhouse: the fleet run-lock is held: %s\n' "$lock" >&2
    exit 75
  }
  printf 'roundhouse: fleet run-lock acquired by hand: %s (held until fleet-unlock)\n' "$lock"
)

fleet_unlock_command() (
  # `roundhouse fleet-unlock [--force]` — release the run lock by hand. A lock
  # whose holder is a VERIFIED-LIVE run (pid, start time and command all match,
  # and not hand-taken) is a run in progress, and removing its lock lets a
  # second run race it; that is refused unless `--force` says so explicitly.
  # Everything else — a hand-taken lock, a dead or unjudgeable holder — goes.
  #
  # The release is by IDENTITY, read in the same breath as the holder check:
  # the lock judged here is the only one removed, so a run that took the lock
  # between the check and the release keeps it. A lock with no meta at all
  # carries nothing to protect and its empty directory goes; one whose meta
  # cannot be read needs `--force`.
  require_jq
  unlock_force=false
  case ${1:-} in
    '') ;;
    --force) unlock_force=true ;;
    *)
      printf 'roundhouse: unknown fleet-unlock option: %s\n' "$1" >&2
      exit 64
      ;;
  esac
  unlock=$(fleet_lock_path)
  [ -d "$unlock" ] || {
    printf 'roundhouse: no fleet run-lock is held\n'
    exit 0
  }
  unlock_id=$(fleet_lock_identity "$unlock")
  if [ "$unlock_force" != true ]; then
    fleet_lock_holder_state "$unlock"
    [ "$fleet_lock_state" != live ] || {
      printf 'roundhouse: a live run (%s) holds %s; refusing to release it (use --force to override)\n' \
        "$(fleet_lock_holder_desc "$unlock")" "$unlock" >&2
      exit 75
    }
  fi
  if [ -n "$unlock_id" ]; then
    fleet_lock_release "$unlock" "$unlock_id" || {
      printf 'roundhouse: %s changed while it was being released (another run took it); nothing released\n' \
        "$unlock" >&2
      exit 75
    }
  elif [ ! -e "$unlock/meta.json" ]; then
    rmdir "$unlock" 2>/dev/null || {
      printf 'roundhouse: %s holds files other than its meta; remove it by hand\n' "$unlock" >&2
      exit 75
    }
  elif [ "$unlock_force" = true ]; then
    rm -f "$unlock/meta.json"
    rmdir "$unlock" 2>/dev/null || :
  else
    printf 'roundhouse: %s has an unreadable meta.json; confirm no live runner, then release it with --force\n' \
      "$unlock" >&2
    exit 75
  fi
  printf 'roundhouse: fleet run-lock released\n'
)

fleet_journal_command() (
  # `roundhouse fleet-journal ENTRY.json|-` — §7.3's evidence surface, by hand.
  # The entry passes the SAME shape gate the run's own writes pass; there is no
  # looser hand-written path, because the canary gate on every other host reads
  # what this writes and cannot tell who typed it.
  fleet_run_env
  require_jq
  require_yq
  journal_source=$1
  journal_tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-journal.XXXXXX")
  trap 'rm -rf "$journal_tmp"' EXIT HUP INT TERM
  if [ "$journal_source" = - ]; then
    cat >"$journal_tmp/entry.json"
  else
    cat "$journal_source" >"$journal_tmp/entry.json"
  fi
  journal_entry=$(jq -c --arg at "$(fleet_now)" '.at //= $at' \
    "$journal_tmp/entry.json") || {
    printf 'roundhouse: fleet-journal input is not JSON\n' >&2
    exit 65
  }
  fleet_journal_append "$(fleet_store_path)" "$(fleet_host_name)" \
    "$journal_entry" || exit 65
  printf '%s\n' "$journal_entry"
)

fleet_finding_command() (
  # `roundhouse fleet-finding SLUG SUMMARY [QUOTE]` — §10.4. A finding is the
  # ONLY mining output that replicates, so every field it carries goes through
  # the redaction floor, and a trip REFUSES rather than silently redacting: the
  # remedy for a published secret cannot un-publish it.
  fleet_run_env
  require_jq
  require_yq
  finding_slug=$1
  case $finding_slug in
    '' | *[!A-Za-z0-9._-]*)
      printf 'roundhouse: invalid finding slug: %s\n' "${finding_slug:-<empty>}" >&2
      exit 64
      ;;
  esac
  [ -n "$2" ] || {
    printf 'roundhouse: fleet-finding requires a summary\n' >&2
    exit 64
  }
  fleet_finding_write "$(fleet_store_path)" "$(fleet_host_name)" \
    "$finding_slug" "$2" ${3+"$3"} || {
    printf 'roundhouse: refusing the finding: a field trips the redaction floor (§10.4)\n' >&2
    exit 65
  }
  printf 'roundhouse: recorded finding %s (working copy only — the next run publishes it)\n' \
    "$finding_slug"
)

fleet_hold_command() (
  # `roundhouse fleet-hold ITEM REASON` — the fleet-visible half of a refusal.
  # `fleet-review ITEM hold` stops THIS host converging; this writes the alert
  # every host sees. They are deliberately two verbs: one is a local decision,
  # the other is a message, and collapsing them would make every local hold
  # shout at the fleet.
  fleet_run_env
  require_jq
  require_yq
  hold_item=$1
  [ -n "$2" ] || {
    printf 'roundhouse: fleet-hold requires a reason\n' >&2
    exit 64
  }
  fleet_item_split "$hold_item" >/dev/null || {
    printf 'roundhouse: fleet-hold needs a <category>.<name> item id\n' >&2
    exit 64
  }
  fleet_alert_write "$(fleet_store_path)" "$(fleet_host_name)" hold \
    "hold-$(printf '%s' "$hold_item" | tr './' '--')" "$2" "$hold_item" || {
    printf 'roundhouse: refusing the hold: the reason trips the redaction floor (§10.4)\n' >&2
    exit 65
  }
  printf 'roundhouse: held %s for the fleet (working copy only — the next run publishes it)\n' \
    "$hold_item"
)

fleet_pending_command() (
  # `roundhouse fleet-pending` — every open alert in the store, from every
  # host, as JSON lines. Resolution is `rm` on the file (§5): there is no state
  # machine, so "pending" is exactly "the file is still there".
  require_jq
  require_yq
  pending_store=$(fleet_store_path)
  [ -d "$pending_store/alerts" ] || return 0
  find "$pending_store/alerts" -type f -name '*.yaml' 2>/dev/null |
    LC_ALL=C sort | while IFS= read -r pending_file; do
    [ -n "$pending_file" ] || continue
    fleet_record_read "$pending_file" '{}' |
      jq -c --arg path "${pending_file#"$pending_store/"}" '. + {alert: $path}'
  done
)
