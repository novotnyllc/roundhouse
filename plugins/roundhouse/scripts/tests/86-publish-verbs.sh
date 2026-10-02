# roundhouse self-check — the verbs that PUBLISH (fleet-compact-alerts,
# fleet-disown) and the pure pieces under them: which working-copy paths are a
# host's own records, and which owned items only a host's own layer wants.
#
# Pure file logic; the publishing itself, against real jj, is in
# tests/93-jj-run.sh.
#
# Sourced by scripts/test-roundhouse in a fixed order; not a
# standalone test file. See that driver for why.
# shellcheck shell=bash

if [ -n "$fleet_fixture_yq" ]; then
  printf 'publish verbs: host-record filter parity, host-only selection\n'
  (
    set -eu
    PATH=$fleet_fixture_path
    export PATH
    # shellcheck source=/dev/null
    ROUNDHOUSE_LIB_ONLY=1 . "$cli"

    # --- fleet_vcs_host_record_filter is fleet_vcs_path_owner, in one pass ---
    # The sample paths are GENERATED from the owner table's own case patterns:
    # every alternative, with each `?*` filled by this host, a peer, and a
    # deeper path on either side — so a row added to fleet_vcs_path_owner is
    # walked here without anyone listing it. The filter must keep exactly the
    # paths the table does not give to vireo.
    pub_patterns=$(cli_function_body fleet_vcs_path_owner |
      awk '{ line = line $0; if (line ~ /\\$/) { sub(/\\$/, "", line); next } }
        # A case ARM: nothing but path-pattern characters, ending in `)`.
        line ~ /^[[:space:]]*[A-Za-z0-9?*\/._| -]+\)[[:space:]]*$/ &&
          line !~ /^[[:space:]]*\*\)/ {
          sub(/\)[[:space:]]*$/, "", line); n = split(line, alt, "|")
          for (i = 1; i <= n; i++) { gsub(/[[:space:]]/, "", alt[i]); print alt[i] }
        }
        { line = "" }')
    [ "$(printf '%s\n' "$pub_patterns" | grep -c .)" -ge 17 ] ||
      fail "the owner table's patterns could not be read: $pub_patterns"
    pub_samples="$tmp/publish-verbs-samples"
    mkdir -p "$(dirname "$pub_samples")"
    : >"$pub_samples"
    # Read, never word-split: the patterns are globs and would expand.
    while IFS= read -r pub_pattern; do
      for pub_fill in vireo wren vireo/deep deep/vireo; do
        for pub_fill2 in vireo wren vireo/deep; do
          pub_path=${pub_pattern/\?\*/$pub_fill}
          pub_path=${pub_path//\?\*/$pub_fill2}
          printf '%s\n' "$pub_path" >>"$pub_samples"
        done
      done
    done <<EOF
$pub_patterns
EOF
    printf '%s\n' README.md .gitignore vireo journal/vireo journal/vireo/ \
      alerts/vireo applied/vireo >>"$pub_samples"
    [ "$(grep -c . "$pub_samples")" -ge 100 ] || fail "too few generated sample paths"
    while IFS= read -r pub_path; do
      pub_owned=no
      [ "$(fleet_vcs_path_owner "$pub_path" 2>/dev/null || true)" != vireo ] ||
        pub_owned=yes
      pub_kept=$(printf '%s\n' "$pub_path" | fleet_vcs_host_record_filter vireo)
      if [ "$pub_owned" = yes ]; then
        [ -z "$pub_kept" ] ||
          fail "the host-record filter kept $pub_path, which the owner table gives vireo"
      else
        [ "$pub_kept" = "$pub_path" ] ||
          fail "the host-record filter dropped $pub_path, which the owner table does not give vireo"
      fi
    done <"$pub_samples"
    # …and the walk reaches every host-keyed row, not only the shared ones.
    for pub_row in journal/vireo/wren alerts/vireo/vireo/deep findings/wren/vireo \
      applied/vireo.yaml applied/vireo/deep.yaml upstreams/wren/vireo.yaml; do
      grep -Fqx "$pub_row" "$pub_samples" || fail "the generated walk missed $pub_row"
    done

    # --- §8.2 P0 fleet-disown --host-only: what only this host's layer wants ---
    verb_store="$tmp/publish-verbs/store"
    mkdir -p "$verb_store/hosts"
    ROUNDHOUSE_FLEET_STORE=$verb_store
    HOME="$tmp/publish-verbs/home"
    export ROUNDHOUSE_FLEET_STORE HOME
    mkdir -p "$HOME"
    fleet_record_write "$(fleet_identity_path)" '{"name":"vireo"}'
    printf '%s\n' 'policy:' '  canary_group: canary' >"$verb_store/fleet.yaml"
    # The shared fold (fleet_disown_shared_fold) is the host's fold without its
    # own tier — its facts still pick the os/ and groups/ tiers.
    pub_mid="$tmp/publish-verbs/shared"
    mkdir -p "$pub_mid/hosts" "$pub_mid/groups"
    printf 'platform: macos\ngroups: [dev]\npackages:\n  host-only: enabled\n' \
      >"$pub_mid/hosts/vireo.yaml"
    printf 'packages:\n  from-group: enabled\n' >"$pub_mid/groups/dev.yaml"
    [ "$(fleet_disown_shared_fold "$pub_mid" vireo | jq -c '.packages | keys')" = '["from-group"]' ] ||
      fail "the shared fold kept the host tier, or lost the group the host's facts select"
    [ "$(fleet_fold "$pub_mid" vireo | jq -c '.packages | keys')" = '["from-group","host-only"]' ] ||
      fail "the ordinary fold lost a tier"
    mkdir -p "$verb_store/groups" "$verb_store/applied"
    printf '%s\n' 'packages:' '  jq: enabled' >"$verb_store/groups/development.yaml"
    printf '%s\n' 'platform: macos' 'groups: [development]' 'plugins:' \
      '  railyard: enabled' '  snapshot-only: enabled' 'packages:' '  jq: enabled' \
      >"$verb_store/hosts/vireo.yaml"
    printf '%s\n' 'packages:' '  ripgrep:' '    homebrew: ripgrep' \
      >"$verb_store/definitions.yaml"
    rm -f "$(fleet_applied_path "$verb_store" vireo)"
    for verb_owned in plugins.railyard plugins.snapshot-only packages.jq \
      definitions.packages.ripgrep plugins.gone-everywhere; do
      fleet_applied_record "$verb_store" vireo "$verb_owned" d-"$verb_owned"
    done
    # Only the host file asks for `railyard` and `snapshot-only`, and nothing
    # asks for `gone-everywhere`; jq is shared through the group, and a
    # definition comes from no host layer at all.
    [ "$(fleet_disown_host_only "$verb_store" vireo | tr '\n' ' ')" = \
      'plugins.gone-everywhere plugins.railyard plugins.snapshot-only ' ] ||
      fail "the host-only selection was wrong: $(fleet_disown_host_only "$verb_store" vireo | tr '\n' ' ')"
    printf '%s\n' 'plugins:' '  railyard: enabled' >>"$verb_store/fleet.yaml"
    [ "$(fleet_disown_host_only "$verb_store" vireo | tr '\n' ' ')" = \
      'plugins.gone-everywhere plugins.snapshot-only ' ] ||
      fail "an item a shared layer also asks for was selected as host-only"
    # A host file that cannot be read must abort the selection: an empty
    # shared fold would make every owned item look host-only.
    cp "$verb_store/hosts/vireo.yaml" "$verb_store/hosts/vireo.yaml.good"
    printf 'platform: [unterminated\n' >"$verb_store/hosts/vireo.yaml"
    if verb_bad=$(fleet_disown_host_only "$verb_store" vireo 2>/dev/null); then
      fail "a malformed host file still produced a host-only selection"
    fi
    [ -z "$verb_bad" ] || fail "a malformed host file selected: $verb_bad"
    mv "$verb_store/hosts/vireo.yaml.good" "$verb_store/hosts/vireo.yaml"
  )
fi
