# roundhouse — the fold: four layers, one left fold, one knockout pass.
#
# §4 of docs/specs/2026-08-06-dsc-storage-design-v2.md. Everything here is pure
# yq/jq over files: no jj, no network, no host mutation. That is the seam the
# test suite depends on (§12.1) — the parts most likely to be wrong are the
# parts that need no repository to exercise.
#
# Sourced by scripts/roundhouse; carries definitions only.
# shellcheck shell=bash

fleet_categories() {
  # §4's CLOSED set. Adding a category here without teaching the apply path
  # about it converges nothing; leaving one out holds every item in the store
  # (see fleet_unknown_categories), which is the deliberate asymmetry: an
  # unknown key inside a known item cannot under-converge, an unknown category
  # can.
  cat <<'EOF'
policy
packages
plugins
skills
agents
hooks
mcp_servers
config_files
projects
EOF
}

fleet_host_fact_keys() {
  # Top-level keys of the host layer that are FACTS, not desired state. They
  # share the namespace with categories, so the unknown-category check has to
  # know them or every host file alerts on itself.
  cat <<'EOF'
platform
hostname
tailnet_name
user
package_managers
groups
wsl_sibling
EOF
}

fleet_definitions_file_path() {
  # A definitions directory is one level deep: the loader's glob is
  # intentionally `definitions/*.yaml`, not a recursive walk. Keep every
  # path-admission seam on that same direct-child rule; shell case `*` also
  # matches `/`, so the suffix check is load-bearing.
  case $1 in
    definitions/*.yaml) fleet_definitions_rel=${1#definitions/} ;;
    *) return 1 ;;
  esac
  case $fleet_definitions_rel in
    ''|.*|*/*) return 1 ;;
  esac
}

fleet_fold_program='. as $layer ireduce ({};
  (. *d ($layer | with_entries(select(.value != null))
    | (.[] | select(tag == "!!map")) |= with_entries(select(.value != null))))
  | (.[] | select(tag == "!!map")) |= with_entries(select(.value != "absent")))'
# The whole merge rule, and the reason it is one expression:
#
#   the first |=  the NULL DROP, applied to the incoming layer BEFORE it
#           merges. §4:416 — a null item value is "no opinion at this layer;
#           skip it", and `*d` does not read it that way: it overwrites with
#           null. A truncated line (`  ponytail:` with nothing after it) in a
#           narrower layer therefore erased the item, `fleet_item_digest`
#           returned 1 on the empty value so it never reached `verdicts`, and
#           the removal loop read "no value in the fold" as "gone from the
#           layers" — producing `fleet_applied_forget` plus a FALSE
#           `outcome: reverted` journal record that every peer then reasons
#           from through §8.2b rule 4 and §10.8's revert signature.
#           The leading `with_entries(select(.value != null))` is the SAME
#           drop one grain coarser: a whole CATEGORY present with a null value
#           (`plugins:` with nothing after it) is a `!!null`, not a `!!map`, so
#           the per-category pass below never reached it and `*d` overwrote the
#           lower layers' entire category with null — no hold, because
#           `fleet_unknown_categories` sees a KNOWN name, and a false fleet-wide
#           `outcome: reverted` for every item it carried.
#           `*dn` is NOT the fix: measured on yq v4.53 its `n` flag means
#           "assign only where the destination is null", which breaks the
#           `absent` knockout and map↔scalar whole-replacement together.
#           Scoped to <category>.<item> for the same reason as the knockout:
#           a null nested inside a config_files value is data.
#   *d      map+map deep merge, anything else replaced whole by the higher
#           layer, a null document contributing nothing — §4, verbatim.
#   the second |=  the `absent` knockout, applied AFTER EACH LAYER and scoped
#           to exactly <category>.<item>. Never a recursive del(.. ==
#           "absent"): a legitimate string "absent" nested inside a
#           config_files value is data and must survive. `select(tag ==
#           "!!map")` skips the host file's scalar and sequence facts
#           (platform, groups) rather than trying to knock out entries they do
#           not have.

fleet_tier_files() (
  # One layer tier, in fold order: `x.yaml`, else `x/*.yaml` merged in
  # filename order (§5's hosts/wren/ split, available at every tier). Both
  # forms are legal at once and the file sorts first, which is the reading
  # that makes `hosts/wren.yaml` + `hosts/wren/skills.yaml` mean what it looks
  # like it means.
  #
  # LC_ALL=C so "filename order" is the same order on every host in the fleet.
  LC_ALL=C
  # …and globbing back ON: the callers below run with `set -f` so that a store
  # path carrying a `*` cannot expand into arguments, and a subshell inherits
  # it — which would leave the one glob this system genuinely wants unexpanded.
  set +f
  tier_root="$1/$2"
  [ ! -f "$tier_root.yaml" ] || printf '%s\n' "$tier_root.yaml"
  for tier_file in "$tier_root"/*.yaml; do
    [ -f "$tier_file" ] || continue
    [ "$2" != definitions ] ||
      fleet_definitions_file_path "definitions/${tier_file##*/}" || continue
    printf '%s\n' "$tier_file"
  done
)

fleet_fold_files() {
  # The fold over an explicit, ordered file list. No files is an empty
  # document, not an error: a store with no layers yet wants nothing.
  [ "$#" -gt 0 ] || {
    printf '{}\n'
    return
  }
  yq ea -o=json -I=0 "$fleet_fold_program" "$@"
}

fleet_host_facts() (
  # Layer 4 alone. The full layer list cannot be built without it — the
  # platform names the os/ file and the host's own `groups:` list order IS the
  # group precedence (§4: no priority field, no alphabetical rule).
  #
  # A SUBSHELL so IFS and noglob are scoped: the file list is newline-separated
  # and a store path carrying a space or a glob character would otherwise split
  # or expand into arguments that name no file, breaking the fold — and under
  # `set -e` at the run's fold call that aborts the run.
  IFS='
'
  set -f
  # shellcheck disable=SC2046 # deliberate word splitting over the file list
  fleet_fold_files $(fleet_tier_files "$1" "hosts/$2")
)

fleet_layer_files() {
  # The four tiers, low to high, as a file list. Group order is the host's own
  # list order, left to right, last wins.
  layer_facts=$(fleet_host_facts "$1" "$2") || return 1
  fleet_tier_files "$1" fleet
  layer_platform=$(printf '%s\n' "$layer_facts" | jq -r '.platform // empty')
  [ -z "$layer_platform" ] || fleet_tier_files "$1" "os/$layer_platform"
  while read -r layer_group; do
    [ -n "$layer_group" ] || continue
    fleet_tier_files "$1" "groups/$layer_group"
  done <<EOF
$(printf '%s\n' "$layer_facts" | jq -r '.groups // [] | .[]')
EOF
  fleet_tier_files "$1" "hosts/$2"
}

fleet_fold() (
  # The effective desired state for one host, as compact JSON. Subshell, IFS
  # and noglob for the same reason as fleet_host_facts.
  IFS='
'
  set -f
  # shellcheck disable=SC2046 # deliberate word splitting over the file list
  fleet_fold_files $(fleet_layer_files "$1" "$2")
)

fleet_item_split() {
  # `<category>.<name>` -> two lines, category then name. The split is on the
  # FIRST dot, because names carry dots freely (`~/.claude/settings.json`,
  # `postgresql@16`) and categories never do — except the one reserved
  # namespace, where `definitions.packages.jj` splits into
  # `definitions.packages` and `jj` (§5.1: the mapping and the desired item
  # are different items, with different digests and different verdicts).
  case $1 in
    definitions.*.*)
      split_rest=${1#definitions.}
      printf 'definitions.%s\n%s\n' "${split_rest%%.*}" "${split_rest#*.}"
      ;;
    *.*) printf '%s\n%s\n' "${1%%.*}" "${1#*.}" ;;
    *) return 1 ;;
  esac
}

fleet_items() {
  # Every item id in a folded document, `<category>.<name>`, skipping the host
  # facts (which are not items and have no digest, no verdict and no apply).
  printf '%s\n' "$1" | jq -r --arg facts "$(fleet_host_fact_keys)" '
    ($facts | split("\n") | map(select(. != ""))) as $facts |
    to_entries[] | select(.value | type == "object") |
    select(.key as $k | $facts | index($k) | not) |
    .key as $category | .value | keys_unsorted[] | "\($category).\(.)"
  '
}

fleet_item_value() {
  # The resolved value of one item out of a folded document, compact JSON, or
  # nothing when the item has no opinion at any layer.
  value_split=$(fleet_item_split "$2") || return 1
  printf '%s\n' "$1" | jq -c \
    --arg c "$(printf '%s\n' "$value_split" | sed -n 1p)" \
    --arg n "$(printf '%s\n' "$value_split" | sed -n 2p)" \
    'getpath([$c, $n]) // empty'
}

# Canonicalize numbers with jq arithmetic (`. + 0`) so number FORM never binds a
# verdict: 12 and 12.0 are one value/one item. yq's own number output is not
# reliable for this — the same yq version normalizes 12.0 on some hosts and
# preserves it on others — so the digest must not depend on it.
fleet_value_normalize='(if type == "object" then . else {state: .} end)
  | walk(if type == "number" then . + 0 else . end)'

fleet_value_digest() {
  # §7.2, and the pipeline is pinned rather than described: yq does YAML->JSON
  # only, jq does the canonicalization it actually can do.
  #
  #   yq -o=json -I=0     comments, key order, quoting, indentation, blank
  #                       lines and LINE ENDINGS drop out. A Windows editor in
  #                       the fleet is why byte-binding is not an option.
  #   jq -Sc + normalize  sorted keys, and `enabled` digests identically to
  #                       `{state: enabled}` — without it §4's reader's-choice
  #                       polymorphism re-reviews an item fleet-wide the day
  #                       someone adds a `marketplace:` key.
  #
  # Known and accepted: the digest canonicalizes number form (12 and 12.0 are
  # the same item, one verdict — see fleet_value_normalize), and YAML 1.1
  # coercion happens before the digest and is visible in it (0755 -> 755,
  # yes -> "yes"). Quote anything where the literal matters.
  # The `|| return 1` cannot see a yq failure on its own: this program sets no
  # `pipefail`, so a failed yq leaves jq reading empty stdin, and jq exits 0
  # having printed nothing. Emptiness IS the failure signal, so it is the one
  # tested — otherwise an unparsable value digests to a stable hash of nothing
  # and every such value looks identical.
  digest_json=$(yq -o=json -I=0 | jq -Sc "$fleet_value_normalize") || return 1
  [ -n "$digest_json" ] || return 1
  printf '%s\n%s\n' "$1" "$digest_json" | sha256_stream
}

fleet_item_digest() {
  # The digest of one item of a folded document: the composition callers
  # actually want, so nobody re-derives the pipeline at a call site.
  digest_value=$(fleet_item_value "$1" "$2") || return 1
  [ -n "$digest_value" ] || return 1
  printf '%s\n' "$digest_value" | fleet_value_digest "$2"
}

fleet_unknown_categories() {
  # §4's asymmetry, the loud half: a top-level key that is neither a known
  # category nor a host fact could mean desired state this reader does not
  # know how to converge, so the run holds EVERYTHING and alerts naming it.
  # Never silent.
  printf '%s\n' "$1" | jq -r --arg known "$(fleet_categories; fleet_host_fact_keys)" '
    ($known | split("\n") | map(select(. != ""))) as $known |
    keys_unsorted[] | select(. as $k | $known | index($k) | not)
  '
}

fleet_known_store_dirs() {
  # Everything the design puts at the store root. A directory outside this set
  # is an unrecognised layer directory (§4) and holds the run the same way an
  # unknown category does: it may carry desired state nothing folded.
  cat <<'EOF'
fleet
definitions
os
groups
hosts
trust
checkpoints
joins
journal
applied
alerts
findings
upstreams
proposals
lineage
.jj
.git
EOF
}

fleet_unknown_layer_dirs() (
  LC_ALL=C
  for store_entry in "$1"/*/ "$1"/.[!.]*/; do
    [ -d "$store_entry" ] || continue
    store_entry=${store_entry%/}
    store_entry=${store_entry##*/}
    fleet_known_store_dirs | grep -Fqx "$store_entry" || printf '%s\n' "$store_entry"
  done
)

fleet_config_key_collisions() {
  # §5's one mechanical validation, and it is a security boundary: `never`
  # beats `managed` from any layer, IN EITHER PREFIX DIRECTION, and a
  # collision is a refusal plus an alert rather than a narrowing.
  #
  # The predicate itself is fleet_allowed_paths_filter, carried from the
  # shipped code unchanged — one definition of "widening", so no writer of a
  # managed config key can drift into disagreeing about what it means. It is
  # asked about ONE key at a time so the alert can name the key rather than
  # only the file; re-deriving the prefix test inline to get that granularity
  # is exactly the drift the shared predicate exists to prevent.
  # Emits `<file><tab><key>` per collision; silence is clean.
  printf '%s\n' "$1" | jq -c '.config_files // {} | to_entries[] |
    .key as $file | (.value.never // []) as $never |
    ((.value.keys // {}) | to_entries[] | select(.value == "managed") | .key) as $key |
    {file: $file, key: $key, allowed: [$key], excluded_namespaces: $never}' |
    jq -r "$fleet_allowed_paths_filter"'
      select(excluded_collisions | length > 0) | [.file, .key] | @tsv'
}

fleet_chezmoi_owns() {
  # §5: chezmoi co-ownership is DETECTED, never required. The source state is
  # queried only when chezmoi is installed and its absence is never an error,
  # so no code path here may make chezmoi a prerequisite.
  #
  # `source-path <target>` is the whole query: it exits non-zero for a target
  # chezmoi does not manage. File granularity is what chezmoi can answer — it
  # owns files, not keys — so a managed key inside a chezmoi-owned file is the
  # co-ownership §5 holds on.
  command -v chezmoi >/dev/null 2>&1 || return 1
  chezmoi source-path -- "$1" >/dev/null 2>&1
}

fleet_config_coowned() {
  # Every `managed` key that a second engine also writes, as
  # `<file><tab><key>`. The operator resolves it by marking the key
  # `unmanaged` here or removing it from the other engine; doctor re-runs this
  # every run so re-emerging co-ownership is caught rather than assumed
  # resolved.
  while IFS=$(printf '\t') read -r coowned_file coowned_key; do
    [ -n "$coowned_file" ] || continue
    ! fleet_chezmoi_owns "$(expand_user_path "$coowned_file")" ||
      printf '%s\t%s\n' "$coowned_file" "$coowned_key"
  done <<EOF
$(printf '%s\n' "$1" | jq -r '.config_files // {} | to_entries[] |
  .key as $file | (.value.keys // {}) | to_entries[] |
  select(.value == "managed") | "\($file)\t\(.key)"')
EOF
}

fleet_validate_ssh_field() {
  # §5's refusal rule applied to the four hand-authored fields that reach
  # ~/.ssh/config.d/roundhouse — `hostname`, `tailnet_name`, `user` and the
  # host `<name>`. A newline in `tailnet_name` would inject arbitrary
  # ssh_config directives (ProxyCommand, LocalForward) into a file every fleet
  # operation reads.
  #
  # This is fleet_validate_fetch_url's RULE, not its regex: that predicate
  # accepts URLs, and `vireo.tail1234.ts.net` is not a URL — reusing it
  # literally would refuse every well-formed host in the fleet. Same refusals
  # (empty, option-looking, whitespace-bearing, credential-bearing,
  # alternate-transport), expressed for a bare token.
  # One case glob, deliberately: `grep -x` matches per LINE, so a value whose
  # FIRST line is well-formed passes it — which is exactly the newline
  # injection this predicate exists to refuse.
  case ${1:-} in
    '' | -* | *[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

fleet_ssh_render_hosts() (
  LC_ALL=C
  for render_entry in "$1"/hosts/*.yaml "$1"/hosts/*/; do
    [ -e "$render_entry" ] || continue
    render_entry=${render_entry%/}
    render_entry=${render_entry##*/}
    printf '%s\n' "${render_entry%.yaml}"
  done
)

fleet_ssh_config_render() (
  # §5's rendered file. The store carries the INGREDIENTS and never an alias:
  # `rh-<name>` is roundhouse's namespace, and the operator's personal aliases
  # stay personal (B-2). HostName is `tailnet_name` when present, else
  # `hostname`.
  #
  # A field that fails validation refuses the WHOLE render and emits no
  # partial file — the caller alerts. Writing half a ProxyCommand-bearing
  # ssh_config is worse than writing none.
  render_store=$1
  render_tmp=$(mktemp "${TMPDIR:-/tmp}/roundhouse-ssh-render.XXXXXX") || return 1
  trap 'rm -f "$render_tmp"' EXIT HUP INT TERM
  printf '%s\n' '# Generated by roundhouse from store/hosts/*.yaml. Do not edit.' \
    '# All fleet transport addresses rh-<name>. Personal aliases stay personal.' \
    >"$render_tmp"
  while read -r render_host; do
    [ -n "$render_host" ] || continue
    render_facts=$(fleet_host_facts "$render_store" "$render_host") || exit 65
    render_user=$(printf '%s\n' "$render_facts" | jq -r '.user // empty')
    render_address=$(printf '%s\n' "$render_facts" |
      jq -r '.tailnet_name // .hostname // empty')
    [ -n "$render_address" ] || continue
    for render_field in "$render_host" "$render_address" "$render_user"; do
      fleet_validate_ssh_field "$render_field" || {
        printf 'roundhouse: refusing to render ssh config: host %s carries an unusable value\n' \
          "$render_host" >&2
        exit 65
      }
    done
    printf 'Host rh-%s\n  HostName %s\n  User %s\n' \
      "$render_host" "$render_address" "$render_user" >>"$render_tmp"
    printf '%s\n' \
      '  IdentityFile ~/.ssh/roundhouse_node_ed25519' \
      '  CertificateFile ~/.ssh/roundhouse_node_ed25519-cert.pub' \
      '  UserKnownHostsFile ~/.ssh/roundhouse_known_hosts' >>"$render_tmp"
  done <<EOF
$(fleet_ssh_render_hosts "$render_store")
EOF
  safe_output "$render_tmp" "$2"
)

fleet_explain_layer_value() {
  # One layer file's OWN opinion about one item, compact JSON, or the empty
  # string when it has none. `""` is unambiguous here because a layer value is
  # a map or a state token, never the empty string.
  FLEET_EXPLAIN_C=$2 FLEET_EXPLAIN_N=$3 yq -o=json -I=0 \
    '.[strenv(FLEET_EXPLAIN_C)][strenv(FLEET_EXPLAIN_N)] // ""' "$1" 2>/dev/null ||
    printf '%s\n' '""'
}

fleet_explain_command() (
  # `roundhouse fleet-explain [HOST] ITEM`. One argument explains this host.
  fleet_run_env
  require_jq
  require_yq
  explain_store=$(fleet_store_path)
  if [ "$#" -eq 2 ]; then
    explain_host=$1
    explain_item=$2
  else
    explain_host=$(fleet_host_name)
    explain_item=$1
  fi
  # HOST reaches `$store/hosts/<name>` as a glob root, so it takes the same
  # predicate every other verb's host argument takes.
  fleet_host_name_ok "$explain_host" || {
    printf 'roundhouse: fleet-explain needs a host name: %s\n' \
      "${explain_host:-<empty>}" >&2
    exit 64
  }
  explain_split=$(fleet_item_split "$explain_item") || {
    printf 'roundhouse: %s is not an item id (<category>.<name>)\n' "$explain_item" >&2
    exit 64
  }
  explain_category=$(printf '%s\n' "$explain_split" | sed -n 1p)
  explain_name=$(printf '%s\n' "$explain_split" | sed -n 2p)
  explain_fold=$(fleet_fold "$explain_store" "$explain_host") || exit 65
  explain_value=$(fleet_item_value "$explain_fold" "$explain_item")
  printf '%s = %s\n\n' "$explain_item" "${explain_value:-<no opinion>}"

  # File, never file:line. [rev2] yq's `line` operator does not count
  # comment-only lines, so on a commented file — which every layer file is by
  # design — the number it reports drifts by however many comments precede the
  # key. A confidently wrong line number is worse than none, so provenance
  # stops at the file. Puppet's `lookup --explain` gives the same.
  explain_layers=$(fleet_layer_files "$explain_store" "$explain_host")
  explain_winner=
  while read -r explain_file; do
    [ -n "$explain_file" ] || continue
    [ "$(fleet_explain_layer_value "$explain_file" "$explain_category" "$explain_name")" = '""' ] ||
      explain_winner=$explain_file
  done <<EOF
$explain_layers
EOF
  while read -r explain_file; do
    [ -n "$explain_file" ] || continue
    explain_at=$(fleet_explain_layer_value "$explain_file" "$explain_category" "$explain_name")
    explain_mark=
    [ "$explain_file" != "$explain_winner" ] || explain_mark='   <- wins'
    if [ "$explain_at" = '""' ]; then
      printf '  %-28s —          (no opinion)\n' "${explain_file#"$explain_store/"}"
    else
      printf '  %-28s %s%s\n' "${explain_file#"$explain_store/"}" "$explain_at" "$explain_mark"
    fi
  done <<EOF
$explain_layers
EOF
)

# --- §5.1 definitions: logical name -> concrete artifact ----------------------
#
# The definitions tier sits at the STORE ROOT and is deliberately outside the
# fold. It accepts `definitions.yaml` plus an ordered `definitions/*.yaml`
# directory. The four layers answer "what does this host want"; a mapping is
# not a want but a lookup, identical for every host that has the manager or
# marketplace. Folding it would invite hosts to disagree about what `jj` is,
# which is not a meaningful disagreement. (Ceiling: a genuine per-host
# divergence — two macOS hosts wanting different taps for one tool — is the
# signal to split it into two logical names, not to layer the definitions.)

fleet_definitions_path() {
  printf '%s/definitions.yaml\n' "$1"
}

fleet_definitions_load() (
  # A missing file or directory reads exactly like an empty one (§4's "no
  # opinion"). `fleet_tier_files` gives definitions the same scalar-plus-
  # sorted-directory forms as every folded layer, while the result remains
  # outside the host fold: definitions are shared lookup data, not desired
  # state.
  IFS='
'
  set -f
  # shellcheck disable=SC2046 # deliberate word splitting over the file list
  fleet_fold_files $(fleet_tier_files "$1" definitions)
)

fleet_definition_entry() {
  # One entry, or nothing. The definitions tier carries ONLY the exceptions:
  # absent an entry the logical name is the concrete name, resolved by that
  # category's default source. `jq` needs no definition and never will.
  printf '%s\n' "$1" | jq -c --arg c "$2" --arg n "$3" 'getpath([$c, $n]) // empty'
}

fleet_definition_items() {
  # Definitions are items like any others, under their own namespace: each one
  # gets a digest, a verdict and apply-time review as
  # `definitions.<category>.<name>`.
  #
  # The prefix is load-bearing, not decoration. Without it `packages.jj` would
  # name two different things — the desired state `enabled` and the mapping
  # `{homebrew: jj, winget: jj-vcs.jj}` — sharing one verdict key and one
  # applied/<host>.yaml entry, so each would clobber the other's digest and
  # the item would sit in permanent apply mismatch.
  printf '%s\n' "$1" | jq -r 'to_entries[] | select(.value | type == "object") |
    .key as $category | .value | keys_unsorted[] | "definitions.\($category).\(.)"'
}

fleet_category_held() {
  # A category the design refuses to apply AT ALL, regardless of what any
  # individual item resolves to. The set is EMPTY, and that is a change: until
  # the trust gate was re-implemented, `hooks` was held outright, because a
  # hook is arbitrary code that runs on every session start and "the gate is
  # coming" is not a gate.
  #
  # The gate now exists (fleet_hook_trust, §5.1.3), so hooks are gated per item
  # instead of held per category — and a standalone hook still has no install
  # path anywhere in this system, which is what keeps "never installable
  # ungated, not even transiently" true by the code's shape.
  #
  # The predicate stays rather than being deleted with its last member: holding
  # a category is a position this design takes, and taking it again is one
  # line here instead of a new mechanism at the apply site.
  case ${1:-} in
    # (nothing) — add a category name here to hold it outright.
    '@never') return 0 ;;
  esac
  return 1
}

fleet_pin_mechanism() {
  # §5.1.1: a pin is ENFORCED or it is REFUSED, never best-effort. A pin that
  # silently degrades to "whatever installed" is worse than no pin, because it
  # reads as a guarantee.
  #
  #   flag     the manager selects an exact version at install time
  #            (winget's --version, apt's pkg=version)
  #   formula  the manager cannot, and the version can only be selected by
  #            installing a differently-named artifact — homebrew, where
  #            `brew install` has no --version flag at all and `brew pin` only
  #            prevents a LATER upgrade of whatever is already installed
  #   (empty)  the manager cannot express it: treat exactly like `unavailable`
  case $1 in
    winget | apt) printf 'flag\n' ;;
    homebrew) printf 'formula\n' ;;
  esac
}

fleet_brew_formula_exists() {
  # The ONLY way a homebrew pin resolves (§5.1.1), and it is §5.1.2's
  # mechanism reused rather than a second one: `<name>@<version>` has to be a
  # real formula.
  #
  #   brew info --json=v2 node@24        -> EXISTS      => pin honoured
  #   brew info --json=v2 postgresql@16  -> EXISTS      => pin honoured
  #   brew info --json=v2 terraform@1.9.8 -> no formula => HOLD + alert
  #
  # A host with no brew cannot answer the question, and an unanswerable
  # question is a hold: never a guess.
  command -v brew >/dev/null 2>&1 || return 1
  brew info --json=v2 "$1" >/dev/null 2>&1
}

fleet_package_pin_candidate() {
  # `<concrete>` when it already names a stream (`node@24`, `postgresql@16` —
  # the formula IS the pin), else `<concrete>@<version>`.
  case $1 in
    *@*) printf '%s\n' "$1" ;;
    *) printf '%s@%s\n' "$1" "$2" ;;
  esac
}

fleet_package_pinned() {
  # The fleet-update contract, as a predicate: an unpinned package is kept
  # current by the update pass — that is the behaviour anyone gets by doing
  # nothing, and `latest` is never written down. A `version:` key opts one
  # package out, and the update pass MUST skip it or it quietly undoes the pin.
  fleet_definition_entry "$1" packages "$2" |
    jq -e 'objects | (.version // ([.[] | objects | .version // empty] | first)) != null' \
      >/dev/null 2>&1
}

fleet_resolve_package() {
  # `fleet_resolve_package DEFS NAME MANAGER...` — the host's own
  # `package_managers:` list picks the manager, in its order; the definition
  # (or the default rule) yields the concrete package and its attributes.
  #
  # Prints one JSON object either way. Exit 0 resolved, exit 75 HELD — and a
  # hold names the logical name and every manager tried, because §5.1's rule
  # is "never a guess, never a silent skip".
  resolve_defs=$1
  resolve_name=$2
  shift 2
  resolve_entry=$(fleet_definition_entry "$resolve_defs" packages "$resolve_name")
  [ -n "$resolve_entry" ] || resolve_entry='{}'
  resolve_detail='no package manager on this host provides it'
  for resolve_manager in "$@"; do
    resolve_spec=$(printf '%s\n' "$resolve_entry" |
      jq -c --arg m "$resolve_manager" --arg n "$resolve_name" '
        # A fleet-wide `version:` applies to every manager that can express
        # it; a per-manager one overrides it. Bound BEFORE the entry is
        # reshaped, because after the reshape `.` is the resolution and no
        # longer the definition.
        .version as $fleet_version |
        .[$m] as $entry |
        # An unknown MANAGER key is ignored by hosts that lack that manager: a
        # Windows-only scoop: entry costs the macOS hosts nothing. An absent
        # key is the default rule, not an error — the file carries exceptions.
        (if $entry == "unavailable" then {unavailable: true}
         elif ($entry | type) == "string" then {name: $entry, attributes: {}}
         elif ($entry | type) == "object" then
           {name: ($entry.name // $n), attributes: ($entry | del(.name, .version))}
         else {name: $n, attributes: {}} end)
        | .version = (($entry | objects | .version) // $fleet_version)') ||
      return 1
    if [ "$(printf '%s\n' "$resolve_spec" | jq -r '.unavailable // false')" = true ]; then
      resolve_detail="explicitly unavailable on $resolve_manager"
      continue
    fi
    resolve_concrete=$(printf '%s\n' "$resolve_spec" | jq -r '.name')
    resolve_version=$(printf '%s\n' "$resolve_spec" | jq -r '.version // empty')
    resolve_pin=null
    if [ -n "$resolve_version" ]; then
      case $(fleet_pin_mechanism "$resolve_manager") in
        flag) resolve_pin='"flag"' ;;
        formula)
          resolve_candidate=$(fleet_package_pin_candidate "$resolve_concrete" "$resolve_version")
          if fleet_brew_formula_exists "$resolve_candidate"; then
            resolve_concrete=$resolve_candidate
            resolve_pin='"formula"'
          else
            resolve_detail="$resolve_manager cannot select version $resolve_version ($resolve_candidate is not a formula)"
            continue
          fi
          ;;
        *)
          resolve_detail="$resolve_manager cannot express version $resolve_version at install time"
          continue
          ;;
      esac
    fi
    printf '%s\n' "$resolve_spec" | jq -c \
      --arg item "packages.$resolve_name" --arg manager "$resolve_manager" \
      --arg concrete "$resolve_concrete" --argjson pin "$resolve_pin" \
      '{item: $item, resolved: true, manager: $manager, name: $concrete,
        version: .version, pin: $pin, attributes: .attributes}'
    return 0
  done
  jq -cn --arg item "packages.$resolve_name" --arg detail "$resolve_detail" \
    --args '{item: $item, resolved: false, hold: "unresolvable",
      detail: $detail, managers_tried: $ARGS.positional}' "$@"
  return 75
}

fleet_skill_root_source() {
  # §5.1.3's zero-config default for a STANDALONE skill: a directory in a
  # configured skill root, and when that directory is a git clone its `origin`
  # remote is the recorded source. This is what the shipped inventory already
  # collects (collect-posix's skill_root walk), read the same two ways here so
  # there is one notion of where a standalone skill came from.
  jq -r '(.skill_roots // [])[] | .path' "$(config_path)" 2>/dev/null |
    while read -r source_root; do
      [ -n "$source_root" ] || continue
      source_dir=$(expand_user_path "$source_root")/$1
      [ -f "$source_dir/SKILL.md" ] || continue
      git -C "$source_dir" remote get-url origin 2>/dev/null | sanitize_remote
      return 0
    done
}

fleet_resolve_surface() {
  # `fleet_resolve_surface DEFS CATEGORY NAME` — plugins, skills, agents and
  # hooks, which are all agent surface and each arrive in one of two delivery
  # forms (§5.1.3):
  #
  #   plugin-delivered  the PLUGIN is the unit of install and the member rides
  #                     it, so a plugin-qualified name (superpowers/brainstorming)
  #                     NEVER needs a definition of its own
  #   standalone        a bare name, installed directly from its own source
  #
  # A definitions entry exists only when the source diverges from the
  # category's default; a host's map-form override still beats it, because the
  # definition is the default source and not a lock.
  surface_defs=$1
  surface_category=$2
  surface_name=$3
  surface_entry=$(fleet_definition_entry "$surface_defs" "$surface_category" "$surface_name")
  [ -n "$surface_entry" ] || surface_entry='{}'
  surface_held=false
  ! fleet_category_held "$surface_category" || surface_held=true
  case $surface_name in
    */*)
      jq -cn --arg c "$surface_category" --arg n "$surface_name" \
        --argjson held "$surface_held" \
        '{item: "\($c).\($n)", delivery: "plugin", plugin: ($n | split("/")[0]),
          member: ($n | split("/")[1]), held: $held}'
      return 0
      ;;
  esac
  surface_default=null
  case $surface_category in
    plugins)
      # The fleet's default marketplace is the harness's own default: a null
      # marketplace means "wherever this harness looks", not a config key this
      # design invents.
      printf '%s\n' "$surface_entry" | jq -c \
        --arg c "$surface_category" --arg n "$surface_name" --argjson held "$surface_held" \
        '{item: "\($c).\($n)", delivery: "marketplace", name: $n,
          marketplace: (.marketplace // null), held: $held}'
      return 0
      ;;
    skills) surface_default=$(fleet_skill_root_source "$surface_name") ;;
    agents) surface_default="$HOME/.claude/agents/$surface_name.md" ;;
  esac
  printf '%s\n' "$surface_entry" | jq -c \
    --arg c "$surface_category" --arg n "$surface_name" \
    --arg default "${surface_default:-}" --argjson held "$surface_held" \
    '{item: "\($c).\($n)", delivery: "standalone", name: $n,
      source: (.source // (if $default == "" then null else $default end)),
      held: $held}'
}

fleet_ensure_tools() {
  # The prerequisite set (§5.1/§12), plus tmux, which the fleet's remote work
  # needs on every host.
  #
  # A TEST hook may substitute the list. It is not a safety gate — it decides
  # what gets installed, not what is trusted — and a fixture that depends on
  # which of jq/yq/jj/tmux the runner happens to ship in /usr/bin is a fixture
  # that passes for the wrong reason on the next runner image.
  if fleet_test_hook "${ROUNDHOUSE_ENSURE_TOOLS:-}"; then
    # shellcheck disable=SC2086 # a space-separated list is the hook's shape
    printf '%s\n' $ROUNDHOUSE_ENSURE_TOOLS
    return
  fi
  cat <<'EOF'
jq
yq
jj
tmux
EOF
}

fleet_user_space_manager() {
  # No sudo, ever. apt is deliberately NOT here: installing through it needs
  # root, and a bootstrap that escalates privilege to fetch a YAML parser is a
  # bootstrap nobody can run unattended. A host with only apt gets the loud
  # hold instead, which is the honest answer.
  for manager_candidate in brew:homebrew winget:winget scoop:scoop; do
    ! command -v "${manager_candidate%%:*}" >/dev/null 2>&1 ||
      {
        printf '%s\n' "${manager_candidate#*:}"
        return 0
      }
  done
  return 1
}

fleet_install_package() {
  # fleet_install_package MANAGER NAME CASK [VERSION] — one user-space install,
  # silent on success. Attributes ride through from the definition, so a new
  # install flag needs no reader change here either.
  #
  # THE VERSION IS PASSED, not merely resolved. §5.1.1: a pin is enforced or it
  # is refused, never best-effort — and the resolver's `pin: flag` was reported
  # to the store while the flag itself was dropped on the way here, so
  # `postgresql@16: {version: "16.4"}` installed latest, the store asserted
  # 16.4, and `fleet_package_pinned` then made the update pass skip it forever.
  # Homebrew needs nothing here: its mechanism is `formula`, and the resolver
  # has already rewritten NAME to `<name>@<version>`.
  #
  # `</dev/null` on every manager: these run inside `while read` loops whose
  # stdin is the verdict or package list, and one greedy child consumed a
  # 4-item run down to 1.
  case $1 in
    homebrew)
      if [ "$3" = true ]; then
        brew install --cask "$2" >/dev/null 2>&1 </dev/null
      else
        brew install "$2" >/dev/null 2>&1 </dev/null
      fi
      ;;
    winget)
      if [ -n "${4:-}" ]; then
        winget install --id "$2" --version "$4" --silent \
          --accept-package-agreements --accept-source-agreements \
          >/dev/null 2>&1 </dev/null
      else
        winget install --id "$2" --silent --accept-package-agreements \
          --accept-source-agreements >/dev/null 2>&1 </dev/null
      fi
      ;;
    scoop) scoop install "$2" >/dev/null 2>&1 </dev/null ;;
    # 75, not 1: a manager with no install path here is a HOLD with the
    # package-hold alert naming it, not the generic "no apply path for this
    # category" branch. apt is the live case — installing through it needs
    # root, and roundhouse never uses sudo (fleet_user_space_manager), so an
    # apt-only host gets the loud hold rather than a silent failure.
    *) return 75 ;;
  esac
}

fleet_ensure_tools_command() (
  # §5.1/§12: `jj`, `jq` and `yq` are hard prerequisites installed BEFORE the
  # store exists, and they resolve through the same definitions.yaml as
  # everything else — one mapping, one code path, no second table of bootstrap
  # package names to drift. tmux rides along because the fleet's remote work
  # needs it.
  #
  # Silent when there is nothing to do and silent when an install succeeds;
  # LOUD when the host cannot get there, because that is the only outcome a
  # human has to act on.
  fleet_run_env
  ensure_missing=
  while read -r ensure_tool; do
    [ -n "$ensure_tool" ] || continue
    command -v "$ensure_tool" >/dev/null 2>&1 ||
      ensure_missing="$ensure_missing $ensure_tool"
  done <<EOF
$(fleet_ensure_tools)
EOF
  [ -n "$ensure_missing" ] || exit 0

  # The bootstrap reads definitions.yaml when there IS a store and falls back
  # to the default rule when there is not — the fresh-host case. It also falls
  # back when the tools that read YAML are themselves what is missing, which
  # is the same case wearing a different hat.
  ensure_defs='{}'
  if command -v jq >/dev/null 2>&1 && command -v yq >/dev/null 2>&1; then
    ensure_defs=$(fleet_definitions_load "$(fleet_store_path)")
  fi
  ensure_manager=$(fleet_user_space_manager) || {
    printf 'roundhouse: cannot install%s: no user-space package manager on this host (homebrew, winget or scoop). Install them by hand; roundhouse never uses sudo.\n' \
      "$ensure_missing" >&2
    exit 69
  }
  ensure_held=
  for ensure_tool in $ensure_missing; do
    ensure_name=$ensure_tool
    ensure_cask=false
    if [ "$ensure_defs" != '{}' ]; then
      ensure_resolved=$(fleet_resolve_package "$ensure_defs" "$ensure_tool" "$ensure_manager") ||
        {
          ensure_held="$ensure_held $ensure_tool($(printf '%s\n' "$ensure_resolved" | jq -r '.detail'))"
          continue
        }
      ensure_name=$(printf '%s\n' "$ensure_resolved" | jq -r '.name')
      ensure_cask=$(printf '%s\n' "$ensure_resolved" | jq -r '.attributes.cask // false')
    fi
    fleet_install_package "$ensure_manager" "$ensure_name" "$ensure_cask" ||
      ensure_held="$ensure_held $ensure_tool(install via $ensure_manager failed)"
  done
  [ -z "$ensure_held" ] || {
    printf 'roundhouse: prerequisites unavailable:%s\n' "$ensure_held" >&2
    exit 69
  }
)
