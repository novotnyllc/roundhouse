# roundhouse — the Claude Code plugin surface: which marketplace a plugin
# comes from, what its installed bytes are, how a stale or unregistered
# marketplace is repaired, and how a tombstoned plugin is uninstalled.
#
# §3.4/§3.5 of the agent-sync design. Every function here asks the native
# manager (`claude plugin …`) or reads its records (installed_plugins.json,
# the marketplace checkouts); none of them decides WHETHER to act — that is
# the run's ordering in lib/fleet-run.sh, which calls in here.
#
# Sourced by scripts/roundhouse; carries definitions only.
# shellcheck shell=bash

fleet_run_settings_path() {
  # The user-scope Claude settings file, CLAUDE_CONFIG_DIR-aware: the one place
  # its path is spelled.
  printf '%s/settings.json\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
}

fleet_run_marketplaces() {
  # The one reader of `claude plugin marketplace list --json`: the registered
  # marketplaces as a JSON ARRAY, whichever shape the manager prints (a bare
  # array, or `{marketplaces: [...]}`). Exit 75 when the manager cannot list.
  fleet_run_mlist=$(claude plugin marketplace list --json 2>/dev/null) || return 75
  printf '%s\n' "$fleet_run_mlist" |
    jq -c 'if type == "array" then . else (.marketplaces // []) end' 2>/dev/null ||
    return 75
}

fleet_run_plugin_catalog() {
  # The source SHA is the byte identity; the catalog version remains useful
  # for the ordinary release advance but is never sufficient by itself.
  # Claude 2.1.229's `--available` view omits plugins already installed on the
  # host, so use it when it has a SHA and fall back to the installed
  # marketplace manifest when it does not. Older managers that fail the
  # `--available` command still reach the manifest path.
  fleet_run_catalog_id=$1
  fleet_run_catalog_name=${fleet_run_catalog_id%@*}
  fleet_run_catalog_market=${fleet_run_catalog_id##*@}
  fleet_run_catalog_json=$(claude plugin list --available --json 2>/dev/null) ||
    fleet_run_catalog_json=
  fleet_run_catalog_entry=$(printf '%s\n' "$fleet_run_catalog_json" |
    jq -e -c --arg id "$fleet_run_catalog_id" '
      (if type == "array" then .[] else (.available // [])[] end) |
      select((.pluginId // .id) == $id and
        (.source | if type == "object" then (.sha // "") else "" end) != "")' \
      2>/dev/null) || fleet_run_catalog_entry=
  [ -n "$fleet_run_catalog_entry" ] && {
    printf '%s\n' "$fleet_run_catalog_entry"
    return 0
  }

  fleet_run_catalog_markets=$(fleet_run_marketplaces) || return 75
  fleet_run_catalog_locations=$(printf '%s\n' "$fleet_run_catalog_markets" |
    jq -r --arg market "$fleet_run_catalog_market" '
      .[] | select(.name == $market) | .installLocation // empty' 2>/dev/null) ||
    return 75
  while IFS= read -r fleet_run_catalog_location; do
    [ -n "$fleet_run_catalog_location" ] || continue
    fleet_run_catalog_manifest="$fleet_run_catalog_location/.claude-plugin/marketplace.json"
    [ -f "$fleet_run_catalog_manifest" ] || continue
    fleet_run_catalog_entry=$(jq -e -c \
      --arg name "$fleet_run_catalog_name" --arg market "$fleet_run_catalog_market" \
      '.plugins[]? | select(.name == $name) |
       . + {pluginId: ($name + "@" + $market), marketplaceName: $market}' \
      "$fleet_run_catalog_manifest" 2>/dev/null) || continue
    [ -n "$fleet_run_catalog_entry" ] || continue
    # A RELATIVE-SOURCE entry (`"source": "./plugin"`) lives inside the
    # marketplace checkout itself and has no SHA of its own: its identity is
    # the checkout's commit (§3.5). Without this every such plugin — impeccable,
    # last30days, and most of claude-plugins-official — held forever as
    # "identity unavailable".
    fleet_run_catalog_rel=$(printf '%s\n' "$fleet_run_catalog_entry" |
      jq -r 'if (.source | type) == "string" then .source else empty end')
    if [ -n "$fleet_run_catalog_rel" ]; then
      fleet_run_catalog_relsha=$(fleet_run_relative_source_sha \
        "$fleet_run_catalog_location" "$fleet_run_catalog_rel" \
        "$fleet_run_catalog_id") || fleet_run_catalog_relsha=
      [ -z "$fleet_run_catalog_relsha" ] ||
        fleet_run_catalog_entry=$(printf '%s\n' "$fleet_run_catalog_entry" |
          jq -c --arg sha "$fleet_run_catalog_relsha" \
            '.source = {source: "relative", path: .source, sha: $sha}')
    fi
    printf '%s\n' "$fleet_run_catalog_entry"
    return 0
  done <<EOF
$fleet_run_catalog_locations
EOF
  return 75
}

fleet_run_marketplace_commit() {
  # fleet_run_marketplace_commit CHECKOUT -> the commit the marketplace
  # checkout was taken at: git HEAD for a clone, the `.gcs-sha` marker for an
  # archive download (claude-plugins-official ships as one). Both are
  # read-only; `rev-parse` neither fetches nor runs hooks. Git is asked only
  # when the checkout is itself a repository: `git -C` walks UP, and an archive
  # checkout under a versioned ~/.claude would otherwise answer with that
  # repository's HEAD.
  fleet_run_mcommit=
  [ ! -e "$1/.git" ] ||
    fleet_run_mcommit=$(git -C "$1" rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null) ||
    fleet_run_mcommit=
  [ -n "$fleet_run_mcommit" ] || [ ! -f "$1/.gcs-sha" ] ||
    fleet_run_mcommit=$(tr -d ' \n\r' <"$1/.gcs-sha")
  printf '%s\n' "$fleet_run_mcommit" | grep -Eq '^[0-9a-fA-F]{40}$' || return 1
  printf '%s\n' "$fleet_run_mcommit"
}

fleet_run_tree_digest() (
  # fleet_run_tree_digest DIR -> one digest over the tree's content: every
  # regular file's relative path and bytes, which of them are EXECUTABLE, and
  # every symlink's relative path and target (a link is never followed). `.git`
  # is excluded, and so are the two markers Claude leaves in an installed copy
  # (`.in_use`, `.orphaned_at`), which are not plugin content. A `chmod +x` or
  # a repointed link is a different plugin, so it is a different digest.
  #
  # Exit non-zero rather than answer a digest it cannot stand behind: an
  # unreadable directory, a tree with nothing in it, or any hashing failure
  # (`pipefail`, and sha256_file_list keeps xargs' status). Two trees that both
  # failed would otherwise hash to the same empty digest and read as identical
  # bytes — and identical bytes is what lets an installed copy skip an update.
  set -o pipefail
  cd "$1" 2>/dev/null || exit 1
  tree_work=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-tree.XXXXXX") || exit 1
  trap 'rm -rf "$tree_work"' EXIT
  find . -name .git -prune -o -type f ! -path ./.in_use ! -path ./.orphaned_at \
    -print0 | LC_ALL=C sort -z >"$tree_work/files" || exit 1
  find . -name .git -prune -o -type f -perm -u+x ! -path ./.in_use ! -path ./.orphaned_at \
    -print0 | LC_ALL=C sort -z >"$tree_work/exec" || exit 1
  find . -name .git -prune -o -type l -print0 | LC_ALL=C sort -z >"$tree_work/links" || exit 1
  [ -s "$tree_work/files" ] || [ -s "$tree_work/links" ] || exit 1
  {
    printf 'files\n'
    sha256_file_list <"$tree_work/files" || exit 1
    printf 'executable\n'
    sha256_stream <"$tree_work/exec" || exit 1
    printf 'links\n'
    while IFS= read -r -d '' tree_link; do
      tree_target=$(readlink -- "$tree_link") || exit 1
      printf '%s\0%s\0' "$tree_link" "$tree_target"
    done <"$tree_work/links" | sha256_stream || exit 1
  } | sha256_stream
)

fleet_run_relative_source_sha() {
  # fleet_run_relative_source_sha CHECKOUT REL ID -> the SHA a relative-source
  # plugin's bytes are identified by. Normally the checkout's commit. But a
  # marketplace moves for every commit to its repository, most of which do not
  # touch this plugin, and the native manager does not reinstall a plugin whose
  # version did not change — so a bare commit compare would demand an update
  # the manager then declines, every pass, forever. When the installed copy's
  # bytes are IDENTICAL to the checkout's, the installed SHA is still the right
  # identity, and that is what this answers. Marketplace checkouts are shallow,
  # so the comparison is of the bytes on disk, not of two commits' trees.
  case $2 in
    . | ./*) ;;
    *) return 1 ;;
  esac
  fleet_run_rel_path=${2#.}
  fleet_run_rel_path=${fleet_run_rel_path#/}
  fleet_run_rel_path=${fleet_run_rel_path%/}
  case /$fleet_run_rel_path/ in
    */../* | */./*) return 1 ;;
  esac
  fleet_run_rel_commit=$(fleet_run_marketplace_commit "$1") || return 1
  fleet_run_rel_installed=$(fleet_run_installed_plugin "$3" 2>/dev/null) ||
    fleet_run_rel_installed='{}'
  fleet_run_rel_isha=$(printf '%s\n' "$fleet_run_rel_installed" | jq -r '.gitCommitSha // empty')
  fleet_run_rel_ipath=$(printf '%s\n' "$fleet_run_rel_installed" | jq -r '.installPath // empty')
  if printf '%s\n' "$fleet_run_rel_isha" | grep -Eq '^[0-9a-fA-F]{40}$' &&
    [ "$fleet_run_rel_isha" != "$fleet_run_rel_commit" ] &&
    [ -n "$fleet_run_rel_ipath" ] && [ -d "$fleet_run_rel_ipath" ] &&
    [ -d "$1/$fleet_run_rel_path" ]; then
    fleet_run_rel_have=$(fleet_run_tree_digest "$fleet_run_rel_ipath") || fleet_run_rel_have=
    fleet_run_rel_want=$(fleet_run_tree_digest "$1/$fleet_run_rel_path") || fleet_run_rel_want=x
    if [ -n "$fleet_run_rel_have" ] && [ "$fleet_run_rel_have" = "$fleet_run_rel_want" ]; then
      printf '%s\n' "$fleet_run_rel_isha"
      return 0
    fi
  fi
  printf '%s\n' "$fleet_run_rel_commit"
}

fleet_run_plugin_catalog_proven() {
  # fleet_run_plugin_catalog_proven ID -> a catalog entry that carries a
  # resolved 40-hex source SHA. Exit 75 when there is no entry, 74 when the
  # entry cannot prove its bytes — distinct, so a caller can say which.
  fleet_run_proven=$(fleet_run_plugin_catalog "$1") || return 75
  printf '%s\n' "$fleet_run_proven" | jq -r '
    .source | if type == "object" then (.sha // "") else "" end' |
    grep -Eq '^[0-9a-fA-F]{40}$' || return 74
  printf '%s\n' "$fleet_run_proven"
}

fleet_run_marketplace_locator_filter='
  # One comparable string for a marketplace source, from either shape: a
  # declaration (`extraKnownMarketplaces[n]` = {source: {source, repo|url|path}})
  # or a registration (`marketplace list --json` = {source, repo, url, path}).
  # A GitHub repository is the same source spelled as `owner/repo` or as its
  # https/ssh git URL, so all three meet on `github:owner/repo`. The git REF
  # (branch or tag) is part of the identity — `#stable` and `#experimental`
  # of one repository are two sources — and no ref is the default branch.
  #
  # fleet_run_skill_source_identity (lib/fleet-run.sh) is a sibling normaliser
  # for skill sources; P1 should merge the two into one source identity.
  def locator:
    (if (.source | type) == "object" then .source else . end) as $s |
    ($s.source // "") as $kind |
    def gh: ascii_downcase | sub("[.]git$"; "") | sub("/$"; "");
    def url: (. // "") | sub("/$"; "") |
      if test("^(https://|ssh://git@|git@)github[.]com[:/]") then
        "github:" + (sub("^(https://|ssh://git@|git@)github[.]com[:/]"; "") | gh)
      else "url:" + sub("[.]git$"; "") end;
    (($s.ref // "") | tostring | if . == "" then "" else "#" + . end) as $ref |
    if $kind == "github" then "github:" + (($s.repo // "") | gh) + $ref
    elif $kind == "git" or $kind == "url" then ($s.url | url) + $ref
    elif $kind == "directory" then "path:" + ($s.path // "")
    else "unknown:" + ($s | tojson) end;
'

fleet_run_marketplace_registered_locator() {
  # fleet_run_marketplace_registered_locator NAME ENTRY -> the locator of the
  # source NAME is REGISTERED from. ENTRY is its `marketplace list --json`
  # entry; a ref the list does not show is read from the manager's own record
  # (plugins/known_marketplaces.json), so a pinned ref is compared, not lost.
  fleet_run_known="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/known_marketplaces.json"
  fleet_run_known_ref=
  [ ! -f "$fleet_run_known" ] ||
    fleet_run_known_ref=$(jq -r --arg n "$1" '.[$n].source.ref // empty' \
      "$fleet_run_known" 2>/dev/null) || fleet_run_known_ref=
  printf '%s\n' "$2" | jq -r --arg ref "$fleet_run_known_ref" \
    "$fleet_run_marketplace_locator_filter"'
    (if (.ref // "") == "" and $ref != "" then . + {ref: $ref} else . end) | locator'
}

fleet_run_marketplace_source() {
  # fleet_run_marketplace_source NAME -> the source the user's own synced
  # declaration (`extraKnownMarketplaces`) registers NAME from. Nothing is
  # returned that is option-shaped or carries whitespace.
  fleet_run_msource=
  fleet_run_msettings=$(fleet_run_settings_path)
  # A declared ref (branch or tag) is kept with `#ref`, so registration
  # resolves the revision the user pinned rather than the default branch.
  [ ! -f "$fleet_run_msettings" ] ||
    fleet_run_msource=$(jq -er --arg n "$1" '
      .extraKnownMarketplaces[$n].source // empty |
      ((.ref // "") | if . == "" then "" else "#" + . end) as $ref |
      if .source == "github" then .repo + $ref
      elif .source == "git" then .url + $ref
      elif .source == "directory" then .path
      elif .source == "url" then .url
      else empty end
    ' "$fleet_run_msettings" 2>/dev/null) || fleet_run_msource=
  case $fleet_run_msource in
    ''|-*|*[[:space:]]*) return 75 ;;
    *'#'*) case ${fleet_run_msource##*#} in ''|*[!A-Za-z0-9._/-]*) return 75 ;; esac ;;
  esac
  printf '%s\n' "$fleet_run_msource"
}

fleet_run_marketplace_repair() {
  # fleet_run_marketplace_repair NAME — §3.5: a plugin held for "marketplace
  # identity unavailable" re-registers and refreshes before it holds again.
  # Registers the marketplace from its configured source when the harness does
  # not know it (or its checkout is gone), then refreshes it, so the caller
  # can look ONCE more. Called directly, never in a command substitution: the
  # outcome is remembered for the rest of the run, so twenty plugins from one
  # broken marketplace cost one refresh, not twenty.
  # A refusal's reason (`fleet_run_repair_reason`) is remembered with it.
  fleet_run_repair_reason=
  case " ${fleet_run_repaired_ok:-} " in *" $1 "*) return 0 ;; esac
  case " ${fleet_run_repaired_failed:-} " in
    *" $1 "*)
      fleet_run_repair_reason=$(printf '%s\n' "${fleet_run_repaired_reasons:-}" |
        awk -v n="$1" '$1 == n { sub(/^[^ ]* /, ""); print; exit }')
      return 75
      ;;
  esac
  fleet_run_repair_rc=0
  fleet_run_marketplace_repair_once "$1" || fleet_run_repair_rc=$?
  if [ "$fleet_run_repair_rc" -eq 0 ]; then
    fleet_run_repaired_ok="${fleet_run_repaired_ok:-} $1"
  else
    fleet_run_repaired_failed="${fleet_run_repaired_failed:-} $1"
    [ -z "$fleet_run_repair_reason" ] ||
      fleet_run_repaired_reasons="${fleet_run_repaired_reasons:-}$1 $fleet_run_repair_reason
"
  fi
  return "$fleet_run_repair_rc"
}

fleet_run_marketplace_repair_reset() {
  # Forget every repair outcome: called at the start of each pass, so a later
  # pass in the same process retries a repair an earlier one could not make.
  fleet_run_repaired_ok=
  fleet_run_repaired_failed=
  fleet_run_repaired_reasons=
  fleet_run_source_ok=
  fleet_run_source_bad=
  fleet_run_source_reasons=
}

fleet_run_marketplace_source_ok() {
  # fleet_run_marketplace_source_ok NAME — READ-ONLY: is NAME registered from
  # the source the user's own declaration (`extraKnownMarketplaces`) names?
  # Exit 0 when it is, or when there is nothing to compare (NAME is not
  # registered, or not declared); 75 when it cannot be listed, or for a
  # same-name REPOINT, with the reason in `fleet_run_repair_reason`. Asked
  # before a catalog entry is accepted and before a marketplace is refreshed:
  # a catalog SHA proves bytes, not that they came from the declared
  # repository. It never refreshes anything, and its answer is remembered
  # for the pass (fleet_run_marketplace_repair_reset), so it costs one list
  # per marketplace per pass. Called directly, never in `$(...)`.
  fleet_run_repair_reason=
  case " ${fleet_run_source_ok:-} " in *" $1 "*) return 0 ;; esac
  case " ${fleet_run_source_bad:-} " in
    *" $1 "*)
      fleet_run_repair_reason=$(printf '%s\n' "${fleet_run_source_reasons:-}" |
        awk -v n="$1" '$1 == n { sub(/^[^ ]* /, ""); print; exit }')
      return 75
      ;;
  esac
  fleet_run_source_list=$(fleet_run_marketplaces) || {
    fleet_run_repair_reason="the registered marketplaces cannot be listed"
    return 75
  }
  fleet_run_source_entry=$(printf '%s\n' "$fleet_run_source_list" | jq -c --arg n "$1" '
    [.[] | select(.name == $n)] | .[0] // empty' 2>/dev/null) || fleet_run_source_entry=
  fleet_run_source_declared=
  fleet_run_source_settings=$(fleet_run_settings_path)
  [ -z "$fleet_run_source_entry" ] || [ ! -f "$fleet_run_source_settings" ] ||
    fleet_run_source_declared=$(jq -r --arg n "$1" \
      "$fleet_run_marketplace_locator_filter"'
      .extraKnownMarketplaces[$n] // empty | locator' \
      "$fleet_run_source_settings" 2>/dev/null) || {
      # A declaration that exists but cannot be read is NOT "not declared":
      # verifying against nothing would accept a repointed same-name source.
      fleet_run_repair_reason="$fleet_run_source_settings cannot be read to check $1's declared source"
      return 75
    }
  if [ -n "$fleet_run_source_declared" ]; then
    fleet_run_source_registered=$(fleet_run_marketplace_registered_locator "$1" \
      "$fleet_run_source_entry") || fleet_run_source_registered=
    if [ "$fleet_run_source_declared" != "$fleet_run_source_registered" ]; then
      fleet_run_repair_reason="$1 is registered from ${fleet_run_source_registered:-an unreadable source} but declared from $fleet_run_source_declared (a same-name repoint)"
      fleet_run_source_bad="${fleet_run_source_bad:-} $1"
      fleet_run_source_reasons="${fleet_run_source_reasons:-}$1 $fleet_run_repair_reason
"
      return 75
    fi
  fi
  fleet_run_source_ok="${fleet_run_source_ok:-} $1"
}

fleet_run_marketplace_repair_once() {
  # An UNREGISTERED name is registered from its declaration (ensure). A
  # REGISTERED one is refreshed from its own registered source and never
  # re-added: every `claude plugin marketplace add` declares the marketplace
  # somewhere (`--scope user|project|local`; there is no flag that only
  # registers), so re-adding would write a declaration this host never made.
  # A registered source that is not the declared one is a same-name REPOINT,
  # and is held rather than refreshed — refreshing it would pull whatever the
  # new source serves under the old name.
  fleet_run_repair_reason=
  fleet_upstream_id_valid "$1" || return 75
  command -v claude >/dev/null 2>&1 || return 75
  fleet_run_repair_list=$(fleet_run_marketplaces) || return 75
  fleet_run_repair_entry=$(printf '%s\n' "$fleet_run_repair_list" | jq -c --arg n "$1" '
    [.[] | select(.name == $n)] | .[0] // empty' 2>/dev/null) || return 75
  if [ -z "$fleet_run_repair_entry" ]; then
    fleet_run_ensure_marketplace "$1" || return 75
  else
    fleet_run_marketplace_source_ok "$1" || return 75
  fi
  claude plugin marketplace update "$1" >/dev/null 2>&1 || return 75
}

fleet_run_ensure_marketplace() {
  # fleet_run_ensure_marketplace NAME — register a declared marketplace that
  # the harness does not know yet. Claude Code registers the synced
  # extraKnownMarketplaces only on an interactive trusted start, so on a host
  # driven headlessly a declared marketplace can stay unregistered forever and
  # every install from it holds. The source comes only from the user's own
  # synced declaration; nothing is registered that the settings do not name.
  fleet_run_ensure_name=$1
  fleet_upstream_id_valid "$fleet_run_ensure_name" || return 75
  command -v claude >/dev/null 2>&1 || return 75
  fleet_run_ensure_list=$(fleet_run_marketplaces) || return 75
  if printf '%s\n' "$fleet_run_ensure_list" | jq -e --arg n "$fleet_run_ensure_name" \
    'any(.[]; .name == $n)' >/dev/null 2>&1; then
    return 0
  fi
  fleet_run_ensure_source=$(fleet_run_marketplace_source "$fleet_run_ensure_name") ||
    return 75
  claude plugin marketplace add "$fleet_run_ensure_source" >/dev/null 2>&1 || return 75
  fleet_run_ensure_list=$(fleet_run_marketplaces) || return 75
  printf '%s\n' "$fleet_run_ensure_list" | jq -e --arg n "$fleet_run_ensure_name" \
    'any(.[]; .name == $n)' >/dev/null 2>&1 || return 75
}

fleet_run_installed_plugins() {
  # The one reader of installed_plugins.json: its `plugins` map, compact. No
  # file means nothing installed yet — `{}`, an empty identity that must
  # proceed to install, not a hold. Only a file that fails to parse is
  # genuinely malformed and holds (75): its silence about a plugin proves
  # nothing.
  fleet_run_installed_file="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/installed_plugins.json"
  [ -f "$fleet_run_installed_file" ] || { printf '{}\n'; return 0; }
  jq -e -c '(.plugins // {}) | if type == "object" then . else error("plugins") end' \
    "$fleet_run_installed_file" 2>/dev/null && return 0
  return 75
}

fleet_run_installed_plugin() {
  # fleet_run_installed_plugin ID -> the user-scoped installed record for ID,
  # or `{}` when it is not installed; 75 when installed_plugins.json is
  # unreadable.
  fleet_run_installed_map=$(fleet_run_installed_plugins) || return 75
  printf '%s\n' "$fleet_run_installed_map" | jq -c --arg id "$1" \
    '(.[$id] // []) | map(select(.scope == "user")) | (.[0] // {})'
}

fleet_run_plugin_market() {
  # fleet_run_plugin_market DEFS NAME VALUE -> the marketplace a plugin item
  # names: the value's own map-form `marketplace`, else its definitions
  # entry's, else nothing — the zero-config form, which the harness resolves
  # itself. Exit 75 when the definition has to be asked and does not resolve.
  plugin_market=$(printf '%s\n' "$3" | jq -r '
    if type == "object" then (.marketplace // "") else "" end' 2>/dev/null) ||
    plugin_market=
  if [ -z "$plugin_market" ]; then
    plugin_market_surface=$(fleet_resolve_surface "$1" plugins "$2") || return 75
    # The surface must be a resolved plugin record whose marketplace is a
    # string or absent: a malformed definition yields no record (the resolver
    # does not fail on it), and treating that as "unqualified" would let a
    # tombstone pick a same-named plugin from another marketplace.
    plugin_market=$(printf '%s\n' "$plugin_market_surface" | jq -er '
      if type == "object" and has("item") and
        ((.marketplace | type) == "string" or .marketplace == null)
      then (.marketplace // "") else error("unresolved") end' 2>/dev/null) ||
      return 75
  fi
  printf '%s\n' "$plugin_market"
}

fleet_run_plugin_identity_matches() {
  # fleet_run_plugin_identity_matches DEFS NAME VALUE — compare a resolved
  # marketplace plugin with the user-scoped installed record before ownership
  # can turn an already-applied item into `nothing`. Return 0 for matching
  # bytes/version, 1 for a reinstall, and 75 when the manager cannot prove the
  # identity — with `fleet_run_identity_reason` naming which proof was missing,
  # because "identity unavailable" on twenty plugins is not a diagnosis.
  #
  # SELF-REPAIR FIRST (§3.5). A catalog that has no entry, or an entry with no
  # SHA, is most often a marketplace that was never registered on a headless
  # host or whose checkout went stale; the hold used to be permanent. The
  # marketplace is re-registered from its configured source and refreshed, and
  # the catalog is asked ONCE more before the item holds.
  fleet_run_identity_reason=
  fleet_run_identity_market=$(fleet_run_plugin_market "$1" "$2" "$3") || {
    fleet_run_identity_reason="the plugin's definition does not resolve"
    return 75
  }
  # An unqualified plugin is resolved by the native harness, so there is no
  # marketplace SHA to compare here; the existing manager presence path stays
  # authoritative for that zero-config form.
  [ -n "$fleet_run_identity_market" ] || return 0
  command -v claude >/dev/null 2>&1 || {
    fleet_run_identity_reason='claude is not on PATH for this run'
    return 75
  }
  # A catalog SHA proves the bytes, not where they came from: a same-name
  # marketplace registered from another repository holds before its catalog
  # is read at all.
  fleet_run_marketplace_source_ok "$fleet_run_identity_market" || {
    fleet_run_identity_reason=$fleet_run_repair_reason
    return 75
  }
  fleet_run_identity_id="$2@$fleet_run_identity_market"
  fleet_run_identity_rc=0
  fleet_run_repair_reason=
  fleet_run_identity_catalog=$(fleet_run_plugin_catalog_proven \
    "$fleet_run_identity_id") || fleet_run_identity_rc=$?
  if [ "$fleet_run_identity_rc" -ne 0 ] &&
    fleet_run_marketplace_repair "$fleet_run_identity_market"; then
    fleet_run_identity_rc=0
    fleet_run_identity_catalog=$(fleet_run_plugin_catalog_proven \
      "$fleet_run_identity_id") || fleet_run_identity_rc=$?
  fi
  case $fleet_run_identity_rc in
    0) ;;
    74)
      fleet_run_identity_reason=${fleet_run_repair_reason:-"the $fleet_run_identity_market catalog entry carries no source SHA, even after a refresh"}
      return 75
      ;;
    *)
      fleet_run_identity_reason=${fleet_run_repair_reason:-"no $fleet_run_identity_market catalog entry for $fleet_run_identity_id, even after re-registering and refreshing the marketplace"}
      return 75
      ;;
  esac
  fleet_run_identity_installed=$(fleet_run_installed_plugin "$fleet_run_identity_id") || {
    fleet_run_identity_reason='installed_plugins.json is unreadable'
    return 75
  }
  fleet_run_identity_sha=$(printf '%s\n' "$fleet_run_identity_catalog" |
    jq -r '.source.sha // empty')
  fleet_run_identity_version=$(printf '%s\n' "$fleet_run_identity_catalog" |
    jq -r '.version // empty')
  fleet_run_identity_installed_sha=$(printf '%s\n' "$fleet_run_identity_installed" |
    jq -r '.gitCommitSha // empty')
  fleet_run_identity_installed_version=$(printf '%s\n' "$fleet_run_identity_installed" |
    jq -r '.version // empty')
  # A catalog entry that states no version proves identity by SHA alone: the
  # manager then records a version of its own making (a SHA prefix), and
  # comparing "" against it demanded a reinstall on every pass.
  [ "$fleet_run_identity_sha" = "$fleet_run_identity_installed_sha" ] &&
    { [ -z "$fleet_run_identity_version" ] ||
      [ "$fleet_run_identity_version" = "$fleet_run_identity_installed_version" ]; }
}

# --- §3.4/§3.5 tombstones: `absent` uninstalls through the harness ----------

fleet_run_tombstone_target() {
  # fleet_run_tombstone_target DEFS NAME VALUE -> the installed user-scoped
  # Claude plugin id a tombstone names, or nothing when it is not installed.
  # Exit 75 when that cannot be decided: an unreadable installed_plugins.json,
  # or an unqualified name that more than one marketplace has installed — an
  # uninstall must name exactly one plugin or none.
  # A definition that cannot be resolved HOLDS (75): only a successful empty
  # answer means "unqualified", or a malformed definition would let the
  # unqualified lookup below uninstall a same-named plugin from another
  # marketplace.
  fleet_run_tomb_market=$(fleet_run_plugin_market "$1" "$2" "$3" 2>/dev/null) ||
    return 75
  case $2 in
    *@*) fleet_run_tomb_id=$2 ;;
    *) fleet_run_tomb_id=${fleet_run_tomb_market:+$2@$fleet_run_tomb_market} ;;
  esac
  if [ -n "$fleet_run_tomb_id" ]; then
    fleet_run_tomb_record=$(fleet_run_installed_plugin "$fleet_run_tomb_id") || return 75
    [ "$fleet_run_tomb_record" = '{}' ] || printf '%s\n' "$fleet_run_tomb_id"
    return 0
  fi
  fleet_run_tomb_map=$(fleet_run_installed_plugins) || return 75
  fleet_run_tomb_ids=$(printf '%s\n' "$fleet_run_tomb_map" | jq -r --arg name "$2" '
    to_entries[] |
    select((.key | split("@")[0]) == $name and
      any((.value // [])[]; .scope == "user")) | .key' 2>/dev/null) || return 75
  case $(printf '%s\n' "$fleet_run_tomb_ids" | grep -c .) in
    0) return 0 ;;
    1) printf '%s\n' "$fleet_run_tomb_ids" ;;
    *) return 75 ;;
  esac
}

fleet_run_claude_running() {
  # Is a `claude` CLI process running on this host? Asked twice, because each
  # view misses one install: `comm` names the native binary even when its path
  # carries spaces (the desktop-bundled copy), but an npm-installed `claude` is
  # `node …/cli.js` and its comm is `node` — only the command line shows that.
  ps -A -o comm= 2>/dev/null | awk '
    { name = $0; sub(/.*\//, "", name) }
    name == "claude" { found = 1; exit }
    END { exit(found ? 0 : 1) }' && return 0
  ps -A -ww -o command= 2>/dev/null | fleet_run_claude_cmdline_match
}

fleet_run_claude_cmdline_match() {
  # stdin: command lines, one per process. Exit 0 when one of them is the
  # Claude Code CLI: argv[0] whose basename is exactly `claude` (the native
  # install and its symlink), or a `node` whose script is a `claude`
  # executable or the `@anthropic-ai/claude-code` package. Only argv[0] and
  # argv[1] are read, so a process that merely MENTIONS claude in its
  # arguments (this awk program, a grep) never matches — and the desktop app,
  # `Claude`, which loads plugins in its own sessions only, does not either.
  # A `node` script path may itself carry spaces (a home directory with a
  # space), so the script is read as everything after argv[0], not as one
  # field. That can over-match a later argument ending in `/claude` — which
  # only DEFERS an uninstall, the safe direction.
  awk '
    { exe = $1; sub(/.*\//, "", exe) }
    exe == "claude" { found = 1; exit }
    exe ~ /^node([0-9.]*)?$/ {
      rest = substr($0, length($1) + 2)
      if (rest ~ /\/@anthropic-ai\/claude-code\// || rest ~ /(^|\/)claude( |$)/) { found = 1; exit }
    }
    END { exit(found ? 0 : 1) }'
}

fleet_run_state_key() {
  # `fleet_run_state_key ITEM` -> ONE safe file-name component for a
  # host-local record keyed by an item id. Item ids come from store content,
  # which every synced host can write, so an id is never a path: one made only
  # of `[A-Za-z0-9._@+-]`, not starting with `.`, is used as it is (the names
  # existing records already have, so an open 24h deferral window survives),
  # and anything else — a `/`, a `..`, a newline — is `sha256-<hex>` of the id.
  case $1 in
    '' | .* | *[!A-Za-z0-9._@+-]*)
      printf 'sha256-%s\n' "$(printf '%s' "$1" | sha256_stream)"
      ;;
    *) printf '%s\n' "$1" ;;
  esac
}

fleet_run_deferral_path() {
  # Host-local, never replicated: when this host first deferred ITEM's
  # uninstall, keyed by digest so a new tombstone value starts a new window.
  printf '%s/deferrals/%s\n' "$(fleet_run_state_dir)" "$(fleet_run_state_key "$1")"
}

fleet_run_tombstone_memo_path() {
  # Host-local: the tombstone digest this host has already converged (applied
  # or satisfied). It is what lets a converged tombstone be a silent no-op on
  # every later pass instead of a fresh `satisfied` record every 20 minutes.
  printf '%s/tombstones/%s\n' "$(fleet_run_state_dir)" "$(fleet_run_state_key "$1")"
}

fleet_run_uninstall_plugin() {
  # fleet_run_uninstall_plugin DEFS ITEM NAME VALUE — converge a Claude plugin
  # to `absent`. Exit 0 uninstalled (verified gone from installed_plugins.json),
  # 70 SATISFIED (not installed — here, and whether or not this host has a
  # harness at all), 75 held.
  #
  # LIVE SESSIONS (§3.5). An ENABLED plugin is loaded into every running
  # `claude` session, and pulling its files out from under one breaks it
  # mid-task. So while a `claude` process runs, the uninstall waits — journaled
  # `held` — for up to 24 hours from this host's FIRST deferral of this digest,
  # then proceeds: a session that never ends must not keep a retired plugin
  # installed forever. A disabled plugin is not loaded and goes immediately.
  #
  # `--keep-data`: the native uninstall otherwise deletes the plugin's
  # persistent data directory (~/.claude/plugins/data/<id>/), and
  # `fleet-rollback` restores the plugin, never that data.
  fleet_run_uninstall_deferral=$(fleet_run_deferral_path "$2")
  fleet_run_uninstall_target=$(fleet_run_tombstone_target "$1" "$3" "$4") || return 75
  [ -n "$fleet_run_uninstall_target" ] || {
    # Gone already, by whatever route: a deferral window for it is over too.
    rm -f "$fleet_run_uninstall_deferral"
    return 70
  }
  command -v claude >/dev/null 2>&1 || return 75
  fleet_run_uninstall_enabled=$(fleet_run_plugin_enabled \
    "$fleet_run_uninstall_target" true) || return 75
  if [ "$fleet_run_uninstall_enabled" != false ] && fleet_run_claude_running; then
    fleet_run_uninstall_digest=$(printf '%s\n' "$4" | fleet_value_digest "$2")
    fleet_run_uninstall_first=$(awk -v d="$fleet_run_uninstall_digest" \
      '$1 == d { print $2; exit }' "$fleet_run_uninstall_deferral" 2>/dev/null)
    case $fleet_run_uninstall_first in
      '' | *[!0-9]*)
        # The window is only as good as this record. If it cannot be written,
        # every pass would be a "first" deferral and the 24h would never end;
        # hold instead, and say so.
        fleet_run_uninstall_first=$(date +%s)
        { mkdir -p "$(dirname "$fleet_run_uninstall_deferral")" &&
          printf '%s %s\n' "$fleet_run_uninstall_digest" "$fleet_run_uninstall_first" \
            >"$fleet_run_uninstall_deferral"; } 2>/dev/null || {
          printf '  hold  %s — the live-session deferral record %s cannot be written\n' \
            "$2" "$fleet_run_uninstall_deferral"
          return 75
        }
        ;;
    esac
    fleet_run_uninstall_left=$((fleet_run_uninstall_first + 86400 - $(date +%s)))
    if [ "$fleet_run_uninstall_left" -gt 0 ]; then
      printf '  defer %s — %s is enabled and a claude session is running; uninstall waits up to %ss more\n' \
        "$2" "$fleet_run_uninstall_target" "$fleet_run_uninstall_left"
      return 75
    fi
    printf '  defer %s — the 24h live-session window has elapsed; uninstalling\n' "$2"
  fi
  claude plugin uninstall --scope user --keep-data "$fleet_run_uninstall_target" \
    >/dev/null 2>&1 || return 75
  # The manager's exit status proves it ran, not that the record is gone.
  [ "$(fleet_run_installed_plugin "$fleet_run_uninstall_target")" = '{}' ] || return 75
  rm -f "$fleet_run_uninstall_deferral"
}
