# roundhouse — plugins are always current: every installed plugin, from every
# marketplace, in both harnesses, follows its upstream on the first pass that
# sees the upstream move.
#
#   fleet_plugins_probe    READ-ONLY and cheap: one `git ls-remote` per
#                          marketplace, in parallel, against the head this
#                          host last refreshed it at. The fast pass asks it at
#                          the poll floor, so a new upstream release is work
#                          even when the store did not move.
#   fleet_plugins_refresh  runs BEFORE the item loop, on the marketplaces that
#                          moved (fast) or all of them (full).
#
# CLAUDE: Roundhouse refreshes each marketplace (`claude plugin marketplace
# update`), so the same pass's identity comparison updates the fleet's own
# plugin items through review → apply → journal; installed plugins that are
# not fleet items are updated in place with `claude plugin update`, never an
# install, enable or removal.
#
# CODEX keeps the plugins of its Git marketplaces current ITSELF: every app
# server start syncs those marketplaces and reinstalls what is installed from
# them, whatever anyone holds. Roundhouse does not upgrade or reinstall a
# Codex plugin; it only TRIGGERS that sync on a host where Codex itself may
# never run (codex-plugin-hooks.mjs sync), and the item loop's
# source-verified automatic approval then covers the fleet's own plugins.
# Hooks of third-party Codex plugins that change upstream stay untrusted until
# the operator approves them, as Codex itself leaves them.
#
# Memos are host-local: store.run/plugin-currency/HARNESS/M.attempted is the
# upstream head this host last refreshed (Claude) or saw Codex sync (Codex)
# M at. The probe compares the remote against it.
#
# Sourced by scripts/roundhouse; carries definitions only.
# shellcheck shell=bash

fleet_plugins_memo_path() {
  # fleet_plugins_memo_path HARNESS MARKET KIND
  printf '%s/plugin-currency/%s/%s.%s\n' "$(fleet_run_state_dir)" "$1" "$2" "$3"
}

fleet_plugins_memo_read() {
  cat "$(fleet_plugins_memo_path "$1" "$2" "$3")" 2>/dev/null || :
}

fleet_plugins_memo_write() {
  # fleet_plugins_memo_write HARNESS MARKET KIND REV — a 40-hex REV only.
  printf '%s\n' "${4:-}" | grep -Eq '^[0-9a-fA-F]{40}$' || return 0
  fleet_plugins_memo_file=$(fleet_plugins_memo_path "$1" "$2" "$3")
  mkdir -p "${fleet_plugins_memo_file%/*}" &&
    printf '%s\n' "$4" >"$fleet_plugins_memo_file.next" &&
    mv -f "$fleet_plugins_memo_file.next" "$fleet_plugins_memo_file"
}

fleet_plugins_remote_head() {
  # fleet_plugins_remote_head URL REF -> the 40-hex commit URL serves at REF
  # (a branch or tag; HEAD when empty). Read-only, never prompts, bounded:
  # anything it cannot answer (offline, a private repository without a
  # credential helper, a ref that does not exist) is exit 1, which the probe
  # reads as "not known to have moved" and leaves to the full pass. No
  # terminal prompt and no credential-manager dialog: this runs unattended.
  case ${1:-} in '' | -* | *[[:space:]]*) return 1 ;; esac
  case ${2:-} in -* | *[!A-Za-z0-9._/-]*) return 1 ;; esac
  if [ -z "${2:-}" ]; then
    set -- "$1" "" HEAD
  else
    set -- "$1" "$2" "refs/heads/$2" "refs/tags/$2" "refs/tags/$2^{}"
  fi
  fleet_plugins_ls_url=$1
  fleet_plugins_ls_ref=$2
  shift 2
  fleet_plugins_ls=$(run_bounded 20 env GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never \
    git ls-remote -- "$fleet_plugins_ls_url" "$@" </dev/null 2>/dev/null) || return 1
  # A ref naming both a branch and a tag resolves to the BRANCH, as
  # `git clone --branch` does; a tag resolves to the commit it peels to.
  printf '%s\n' "$fleet_plugins_ls" | awk -v ref="$fleet_plugins_ls_ref" '
    ref == "" && $2 == "HEAD" { head = $1 }
    ref != "" && $2 == "refs/tags/" ref "^{}" { peeled = $1 }
    ref != "" && $2 == "refs/heads/" ref { branch = $1 }
    ref != "" && $2 == "refs/tags/" ref { tag = $1 }
    END {
      out = branch != "" ? branch : (peeled != "" ? peeled : (tag != "" ? tag : head))
      if (out ~ /^[0-9a-fA-F]+$/ && length(out) == 40) { print out; exit 0 }
      exit 1
    }'
}

fleet_plugins_claude_installed_markets() {
  # The marketplaces this host has a user-scoped Claude plugin installed
  # from, read from installed_plugins.json alone (no manager process).
  fleet_plugins_cim=$(fleet_run_installed_plugins 2>/dev/null) || return 0
  printf '%s\n' "$fleet_plugins_cim" | jq -r '
    to_entries[] | select(any((.value // [])[]?; .scope == "user")) |
    .key | select(test("^[^@]+@[^@]+$")) | split("@")[1]' 2>/dev/null |
    while IFS= read -r fleet_plugins_cim_market; do
      ! fleet_upstream_id_valid "$fleet_plugins_cim_market" ||
        printf '%s\n' "$fleet_plugins_cim_market"
    done | LC_ALL=C sort -u
}

fleet_plugins_claude_sources() {
  # `claude NAME URL REF LOCATION`, \037-separated (fleet_run_sep: an empty
  # field must not collapse the way tabs do under `read`), for every Claude
  # marketplace this host has an installed plugin from, read from the
  # manager's own records (plugins/known_marketplaces.json). A GitHub source is
  # asked at its https URL whatever form the checkout took: an archive
  # download's `.gcs-sha` is that repository's commit. Directory and URL
  # sources have no upstream head to ask; the full pass refreshes them.
  fleet_plugins_known="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/known_marketplaces.json"
  [ -f "$fleet_plugins_known" ] || return 0
  fleet_plugins_claude_installed_markets | jq -R -r --slurpfile known "$fleet_plugins_known" '
    . as $name | ($known[0][$name] // empty) as $m | ($m.source // {}) as $s |
    (if $s.source == "github" and (($s.repo // "") | test("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$"))
       then "https://github.com/\($s.repo).git"
     elif $s.source == "git" then ($s.url // "")
     else "" end) as $url |
    select($url != "") |
    ["claude", $name, $url, (($s.ref // "") | tostring),
      (($m.installLocation // "") | tostring)] | join("\u001f")' 2>/dev/null || :
}

fleet_plugins_codex_markets() {
  # The Codex Git marketplaces, `NAME URL REF ROOT`, \037-separated. Local and
  # remote-catalog marketplaces (the bundled and curated ones) advance with
  # Codex itself and have no checkout for anyone else to pull.
  command -v codex >/dev/null 2>&1 || return 0
  fleet_plugins_cm=$(bounded_query codex plugin marketplace list --json 2>/dev/null) ||
    return 0
  printf '%s\n' "$fleet_plugins_cm" | jq -r '
    (if type == "array" then . else (.marketplaces // []) end)[] |
    select((.marketplaceSource.sourceType // "") == "git") |
    [(.name // ""), (.marketplaceSource.source // ""), (.root // "")] |
    select(all(.[]; type == "string" and . != "" and (contains("\u001f") | not))) |
    join("\u001f")' 2>/dev/null |
    while IFS=$fleet_run_sep read -r fleet_plugins_cm_name fleet_plugins_cm_url \
      fleet_plugins_cm_root; do
      fleet_upstream_id_valid "$fleet_plugins_cm_name" || continue
      fleet_plugins_cm_ref=$(jq -r '.ref_name // "" | strings' \
        "$fleet_plugins_cm_root/.codex-marketplace-install.json" 2>/dev/null) ||
        fleet_plugins_cm_ref=
      printf '%s\n' "$fleet_plugins_cm_name$fleet_run_sep$fleet_plugins_cm_url$fleet_run_sep$fleet_plugins_cm_ref$fleet_run_sep$fleet_plugins_cm_root"
    done
}

fleet_plugins_codex_revision() {
  # fleet_plugins_codex_revision ROOT -> the revision a Codex marketplace
  # checkout is at: its git HEAD, else the install marker Codex writes.
  fleet_run_marketplace_commit "$1" 2>/dev/null && return 0
  jq -er '.revision | strings | select(test("^[0-9a-fA-F]{40}$"))' \
    "$1/.codex-marketplace-install.json" 2>/dev/null
}

fleet_plugins_ask_heads() {
  # fleet_plugins_ask_heads SOURCES OUT — SOURCES holds `HARNESS NAME URL REF
  # LOCATION` lines (\037-separated); OUT gets `HARNESS NAME HEAD LOCATION`
  # for every one whose upstream answered a head, asked in parallel.
  fleet_plugins_heads_dir=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-plugins.XXXXXX") ||
    return 1
  fleet_plugins_heads_n=0
  fleet_plugins_heads_pids=
  : >"$fleet_plugins_heads_dir/index"
  while IFS=$fleet_run_sep read -r fleet_plugins_h fleet_plugins_m fleet_plugins_url \
    fleet_plugins_ref fleet_plugins_loc; do
    [ -n "$fleet_plugins_m" ] || continue
    fleet_plugins_heads_n=$((fleet_plugins_heads_n + 1))
    printf '%s\n' "$fleet_plugins_heads_n$fleet_run_sep$fleet_plugins_h$fleet_run_sep$fleet_plugins_m$fleet_run_sep$fleet_plugins_loc" \
      >>"$fleet_plugins_heads_dir/index"
    fleet_plugins_remote_head "$fleet_plugins_url" "$fleet_plugins_ref" \
      >"$fleet_plugins_heads_dir/$fleet_plugins_heads_n" 2>/dev/null </dev/null &
    fleet_plugins_heads_pids="$fleet_plugins_heads_pids $!"
  done <"$1"
  for fleet_plugins_pid in $fleet_plugins_heads_pids; do
    wait "$fleet_plugins_pid" 2>/dev/null || :
  done
  while IFS=$fleet_run_sep read -r fleet_plugins_n fleet_plugins_h fleet_plugins_m \
    fleet_plugins_loc; do
    fleet_plugins_head=$(cat "$fleet_plugins_heads_dir/$fleet_plugins_n" 2>/dev/null) ||
      continue
    [ -n "$fleet_plugins_head" ] || continue
    printf '%s\n' "$fleet_plugins_h$fleet_run_sep$fleet_plugins_m$fleet_run_sep$fleet_plugins_head$fleet_run_sep$fleet_plugins_loc"
  done <"$fleet_plugins_heads_dir/index" >"$2"
  rm -rf "$fleet_plugins_heads_dir"
}

fleet_plugins_probe() {
  # Sets `fleet_plugins_moved` to `HARNESS NAME HEAD LOCATION` lines
  # (\037-separated), one per
  # marketplace whose upstream head differs from the one this host last
  # refreshed it at, and `fleet_plugins_probed=true`; exit 0 when any moved.
  # Called directly, never in `$(...)`: the pass reads both afterwards.
  fleet_plugins_probed=true
  fleet_plugins_moved=
  fleet_plugins_probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-plugins.XXXXXX") ||
    return 1
  {
    ! command -v claude >/dev/null 2>&1 || fleet_plugins_claude_sources
    fleet_plugins_codex_markets | awk -v us="$fleet_run_sep" '{ print "codex" us $0 }'
  } >"$fleet_plugins_probe_dir/sources" 2>/dev/null || :
  : >"$fleet_plugins_probe_dir/heads"
  fleet_plugins_ask_heads "$fleet_plugins_probe_dir/sources" \
    "$fleet_plugins_probe_dir/heads" || :
  while IFS=$fleet_run_sep read -r fleet_plugins_h fleet_plugins_m fleet_plugins_head \
    fleet_plugins_loc; do
    [ "$fleet_plugins_head" != \
      "$(fleet_plugins_memo_read "$fleet_plugins_h" "$fleet_plugins_m" attempted)" ] ||
      continue
    fleet_plugins_moved="$fleet_plugins_moved$fleet_plugins_h$fleet_run_sep$fleet_plugins_m$fleet_run_sep$fleet_plugins_head$fleet_run_sep$fleet_plugins_loc
"
  done <"$fleet_plugins_probe_dir/heads"
  rm -rf "$fleet_plugins_probe_dir"
  [ -n "$fleet_plugins_moved" ]
}

fleet_plugins_owned() {
  # fleet_plugins_owned DESIRED DEFS -> `id NAME@MARKET` or `name NAME` for
  # every plugin the fleet has an item for, in either harness: every
  # `plugins.*` in DESIRED — the fold PLUS its `absent` tombstones
  # (fleet_run_desired), held or not — and every `definitions.plugins.*` in
  # DEFS. Those converge, or are deliberately held, through the item loop
  # (review, journal, applied/); the in-place refresh never touches one,
  # whichever harness installed it. A plugin whose marketplace cannot be
  # resolved here, and every definition, is excluded by name: the safe
  # direction.
  printf '%s\n' "$2" | jq -r '(.plugins // {}) | objects | keys[] |
    select(contains("\n") | not) | "name " + split("@")[0]' 2>/dev/null || :
  printf '%s\n' "$1" | jq -r '(.plugins // {}) | to_entries[] |
    select(.key | contains("\u001f") or contains("\n") | not) |
    [.key, (.value | tojson)] | join("\u001f")' 2>/dev/null |
    while IFS=$fleet_run_sep read -r fleet_plugins_ok fleet_plugins_ov; do
      case $fleet_plugins_ok in
        '') continue ;;
        *@*) printf 'id %s\n' "$fleet_plugins_ok"; continue ;;
      esac
      fleet_plugins_om=$(fleet_run_plugin_market "$2" "$fleet_plugins_ok" \
        "$fleet_plugins_ov" 2>/dev/null) || fleet_plugins_om=
      if [ -n "$fleet_plugins_om" ]; then
        printf 'id %s@%s\n' "$fleet_plugins_ok" "$fleet_plugins_om"
      else
        printf 'name %s\n' "$fleet_plugins_ok"
      fi
    done
}

fleet_plugins_claude_refresh() {
  # fleet_plugins_claude_refresh STORE HOST MARKET — §10.5's refresh of one
  # Claude marketplace, recorded under upstreams/. `update` cannot refresh a
  # marketplace that was never registered, and never refreshes one
  # registered from another source than the declared one: that would pull
  # whatever the new source serves under the name. Exit 0 when refreshed.
  fleet_plugins_cr_result=unavailable
  fleet_plugins_cr_rc=1
  if command -v claude >/dev/null 2>&1; then
    fleet_plugins_cr_result=failed
    fleet_run_ensure_marketplace "$3" >/dev/null 2>&1 || :
    if fleet_run_marketplace_source_ok "$3"; then
      fleet_run_cli_invalidate
      if bounded_verb claude plugin marketplace update "$3" >/dev/null 2>&1; then
        fleet_plugins_cr_result=ok
        fleet_plugins_cr_rc=0
      fi
    else
      fleet_plugins_cr_result=held
      printf '  hold  marketplace %s — %s\n' "$3" "$fleet_run_repair_reason"
    fi
  fi
  fleet_upstream_write "$1" "$3" "$2" "$fleet_plugins_cr_result" || :
  return "$fleet_plugins_cr_rc"
}

fleet_plugins_claude_update_unowned() {
  # fleet_plugins_claude_update_unowned DEFS MARKET OWNED — every installed
  # user-scoped Claude plugin from MARKET that is not a fleet item (OWNED,
  # fleet_plugins_owned) and whose installed bytes are not the
  # catalog's: `claude plugin update`, then the same identity proof the item
  # path requires before it reads the update as done. Exit 0 only when every
  # one CONVERGED (current, or updated and proven); any hold, or an installed
  # list that cannot be read, is 1, so the caller does not remember the
  # marketplace as caught up and the next pass retries.
  fleet_plugins_cu_map=$(fleet_run_installed_plugins 2>/dev/null) || return 1
  fleet_plugins_cu_ids=$(printf '%s\n' "$fleet_plugins_cu_map" | jq -r --arg m "$2" '
    to_entries[] | select(any((.value // [])[]?; .scope == "user")) |
    .key | select(test("^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+$")) |
    select(split("@")[1] == $m)' 2>/dev/null) || return 1
  fleet_plugins_cu_ids=$(printf '%s\n' "$fleet_plugins_cu_ids" | fleet_plugins_order)
  fleet_plugins_cu_converged=0
  # Read on fd 9: the body runs `claude`, and a greedy child must not eat
  # the rest of the list.
  while IFS= read -r fleet_plugins_cu_id <&9; do
    [ -n "$fleet_plugins_cu_id" ] || continue
    fleet_plugins_cu_name=${fleet_plugins_cu_id%@*}
    ! grep -Fqx -e "id $fleet_plugins_cu_id" -e "name $fleet_plugins_cu_name" "$3" ||
      continue
    fleet_plugins_cu_value=$(jq -cn --arg m "$2" '{marketplace: $m}')
    fleet_plugins_cu_status=0
    fleet_run_plugin_identity_matches "$1" "$fleet_plugins_cu_name" \
      "$fleet_plugins_cu_value" || fleet_plugins_cu_status=$?
    case $fleet_plugins_cu_status in
      0) continue ;;
      1) ;;
      *)
        printf '  hold  plugin %s — installed marketplace identity unavailable (%s)\n' \
          "$fleet_plugins_cu_id" "${fleet_run_identity_reason:-unproven}"
        fleet_plugins_cu_converged=1
        continue
        ;;
    esac
    fleet_run_cli_invalidate
    fleet_plugins_cu_ok=false
    if bounded_verb claude plugin update "$fleet_plugins_cu_id" --scope user \
      >/dev/null 2>&1 </dev/null &&
      fleet_run_plugin_identity_matches "$1" "$fleet_plugins_cu_name" \
        "$fleet_plugins_cu_value"; then
      fleet_plugins_cu_ok=true
    fi
    if [ "$fleet_plugins_cu_ok" = true ]; then
      printf '  update plugin %s (claude)\n' "$fleet_plugins_cu_id"
    else
      printf '  hold  plugin %s — claude plugin update did not reach the catalog identity\n' \
        "$fleet_plugins_cu_id"
      fleet_plugins_cu_converged=1
    fi
  done 9<<EOF
$fleet_plugins_cu_ids
EOF
  return "$fleet_plugins_cu_converged"
}

fleet_plugins_order() {
  # stdin: plugin ids -> unique, sorted, `roundhouse@novotnyllc` last (it is
  # the executor running this pass).
  LC_ALL=C sort -u | awk 'NF == 0 { next }
    $0 == "roundhouse@novotnyllc" { last = $0; next }
    { print } END { if (last != "") print last }'
}

fleet_plugins_codex_sync() {
  # fleet_plugins_codex_sync TARGETS — TARGETS holds `NAME HEAD ROOT` lines
  # (\037-separated): Codex Git marketplaces whose upstream is at HEAD.
  # Trigger Codex's OWN sync once (an app server held open until every ROOT
  # records its HEAD, or the deadline), and remember a HEAD only for a
  # marketplace Codex actually reached: a sync that did not happen is retried.
  # Nothing here upgrades, installs or re-trusts anything.
  [ -s "$1" ] || return 0
  command -v codex >/dev/null 2>&1 || return 0
  fleet_plugins_cs_node=$(fleet_node_path) || {
    printf '  hold  Codex marketplace sync — Node.js is required to start the Codex app server\n'
    return 0
  }
  fleet_plugins_cs_args=()
  while IFS=$fleet_run_sep read -r fleet_plugins_cs_m fleet_plugins_cs_head \
    fleet_plugins_cs_root; do
    [ -n "$fleet_plugins_cs_root" ] && [ -n "$fleet_plugins_cs_head" ] || continue
    fleet_plugins_cs_args+=("$fleet_plugins_cs_root" "$fleet_plugins_cs_head")
  done <"$1"
  [ "${#fleet_plugins_cs_args[@]}" -gt 0 ] || return 0
  # The helper reports which roots it saw reach their revision WITH their
  # installed plugins reinstalled at it (Codex records the revision first).
  # A root counts only when the helper says so: a marker an earlier, cut-off
  # sync left at the head proves nothing about the plugins.
  fleet_plugins_cs_out=$(run_bounded 45 "$fleet_plugins_cs_node" \
    "$script_dir/codex-plugin-hooks.mjs" sync "${fleet_plugins_cs_args[@]}" 2>/dev/null </dev/null) || :
  fleet_plugins_cs_missing='*unknown*'
  [ -z "$fleet_plugins_cs_out" ] ||
    fleet_plugins_cs_missing=$(printf '%s\n' "$fleet_plugins_cs_out" |
      jq -r '.missing | if type == "array" then .[] else error("shape") end' 2>/dev/null) ||
    fleet_plugins_cs_missing='*unknown*'
  while IFS=$fleet_run_sep read -r fleet_plugins_cs_m fleet_plugins_cs_head \
    fleet_plugins_cs_root; do
    fleet_upstream_id_valid "$fleet_plugins_cs_m" && [ -n "$fleet_plugins_cs_head" ] || continue
    if [ "$fleet_plugins_cs_missing" != '*unknown*' ] &&
      ! printf '%s\n' "$fleet_plugins_cs_missing" | grep -Fqx -- "$fleet_plugins_cs_root" &&
      [ "$(fleet_plugins_codex_revision "$fleet_plugins_cs_root" 2>/dev/null)" = \
        "$fleet_plugins_cs_head" ]; then
      fleet_plugins_memo_write codex "$fleet_plugins_cs_m" attempted "$fleet_plugins_cs_head" || :
    else
      printf '  hold  marketplace %s (codex) — Codex did not sync it to %s this pass\n' \
        "$fleet_plugins_cs_m" "$fleet_plugins_cs_head"
    fi
  done <"$1"
}

fleet_plugins_refresh() (
  # fleet_plugins_refresh STORE HOST FOLD DEFS MODE HOLD-DIR [DESIRED] — run
  # before the
  # item loop. MODE `full` refreshes every Claude marketplace a fleet plugin
  # resolves to (held ones excepted, as fleet_run_plugin_marketplaces decides)
  # or an installed plugin comes from, and triggers Codex's own sync for every
  # Codex Git marketplace whose upstream answers; `fast` only those
  # fleet_plugins_probe found moved (asking it now if the poll floor did not). DESIRED (fleet_run_desired: the fold plus its
  # tombstones; FOLD when omitted) names the plugins the fleet owns, which the
  # in-place updates leave to the item loop. A refresh failure holds that
  # marketplace and nothing else; it never fails the pass.
  fleet_plugins_r_store=$1
  fleet_plugins_r_host=$2
  fleet_plugins_r_fold=$3
  fleet_plugins_r_defs=$4
  fleet_plugins_r_holds=${6:-}
  fleet_plugins_r_desired=${7:-$3}
  fleet_plugins_r_tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-plugins.XXXXXX") || exit 0
  trap 'rm -rf "$fleet_plugins_r_tmp"' EXIT
  : >"$fleet_plugins_r_tmp/claude"
  : >"$fleet_plugins_r_tmp/codex"
  if [ "$5" = full ]; then
    {
      fleet_run_plugin_marketplaces "$fleet_plugins_r_fold" "$fleet_plugins_r_defs" \
        "$fleet_plugins_r_holds/sigholds" "$fleet_plugins_r_holds/verdicts"
      fleet_plugins_claude_installed_markets
    } | LC_ALL=C sort -u | awk -v us="$fleet_run_sep" 'NF { print $1 us us }' \
      >"$fleet_plugins_r_tmp/claude"
    fleet_plugins_codex_markets | awk -v us="$fleet_run_sep" '{ print "codex" us $0 }' \
      >"$fleet_plugins_r_tmp/codex-sources"
    fleet_plugins_ask_heads "$fleet_plugins_r_tmp/codex-sources" \
      "$fleet_plugins_r_tmp/codex-heads" || : >"$fleet_plugins_r_tmp/codex-heads"
    awk -F"$fleet_run_sep" -v us="$fleet_run_sep" '{ print $2 us $3 us $4 }' \
      "$fleet_plugins_r_tmp/codex-heads" >"$fleet_plugins_r_tmp/codex"
  else
    [ "${fleet_plugins_probed:-}" = true ] || fleet_plugins_probe || :
    printf '%s' "${fleet_plugins_moved:-}" |
      awk -F"$fleet_run_sep" -v us="$fleet_run_sep" \
        -v c="$fleet_plugins_r_tmp/claude" -v x="$fleet_plugins_r_tmp/codex" '
        $1 == "claude" { print $2 us $3 us $4 > c }
        $1 == "codex" { print $2 us $3 us $4 > x }'
  fi

  # Codex first: the item loop's automatic approval reads Codex's copy.
  fleet_plugins_codex_sync "$fleet_plugins_r_tmp/codex" || :

  if [ -s "$fleet_plugins_r_tmp/claude" ]; then
    fleet_plugins_owned "$fleet_plugins_r_desired" "$fleet_plugins_r_defs" \
      >"$fleet_plugins_r_tmp/owned"
    fleet_plugins_r_known="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/known_marketplaces.json"
    # Read on fd 9: the body runs `claude`, and a greedy child must not eat
    # the rest of the list.
    while IFS=$fleet_run_sep read -r fleet_plugins_r_m fleet_plugins_r_head \
      fleet_plugins_r_loc <&9; do
      fleet_upstream_id_valid "$fleet_plugins_r_m" || continue
      fleet_plugins_claude_refresh "$fleet_plugins_r_store" "$fleet_plugins_r_host" \
        "$fleet_plugins_r_m" || continue
      if [ -z "$fleet_plugins_r_head" ]; then
        [ -n "$fleet_plugins_r_loc" ] || fleet_plugins_r_loc=$(jq -r --arg n "$fleet_plugins_r_m" \
          '.[$n].installLocation // empty | strings' "$fleet_plugins_r_known" 2>/dev/null) ||
          fleet_plugins_r_loc=
        [ -z "$fleet_plugins_r_loc" ] ||
          fleet_plugins_r_head=$(fleet_run_marketplace_commit "$fleet_plugins_r_loc") ||
          fleet_plugins_r_head=
      fi
      # Remember the head only once every plugin from it converged: a failed
      # or unproven update leaves the marketplace unremembered, and the next
      # fast pass retries it.
      fleet_plugins_claude_update_unowned "$fleet_plugins_r_defs" "$fleet_plugins_r_m" \
        "$fleet_plugins_r_tmp/owned" || continue
      fleet_plugins_memo_write claude "$fleet_plugins_r_m" attempted "$fleet_plugins_r_head" || :
    done 9<"$fleet_plugins_r_tmp/claude"
  fi

)
