# roundhouse self-check — §5.1 definitions: logical name -> concrete artifact.
#
# The default rule is the whole point, so most of what is asserted here is what
# happens with NO entry at all. Everything below is pure yq/jq over file
# fixtures; the one probe that would reach the network (homebrew's formula
# lookup) is stubbed, never the real brew.
#
# Sourced by scripts/test-roundhouse in a fixed order; not a
# standalone test file. See that driver for why.
# shellcheck shell=bash

if [ -n "$fleet_fixture_yq" ]; then
  printf 'definitions: §5.1 resolution, pins, streams, hook delivery forms\n'
  (
    set -eu
    PATH=$fleet_fixture_path
    export PATH
    # shellcheck source=/dev/null
    ROUNDHOUSE_LIB_ONLY=1 . "$cli"

    defs_store="$tmp/definitions/store"
    defs_root="$tmp/definitions"
    mkdir -p "$defs_store/hosts"

    # A store with no definitions.yaml at all: a fleet that never hits a
    # divergence never creates the file, and a missing file must read exactly
    # like an empty one.
    [ "$(fleet_definitions_load "$defs_store")" = '{}' ] ||
      fail "a missing definitions.yaml did not read as an empty document"
    defs_none=$(fleet_definitions_load "$defs_store")
    [ "$(fleet_resolve_package "$defs_none" jq homebrew | jq -r '.name')" = jq ] ||
      fail "the default rule did not make the logical name the concrete name"

    cat >"$(fleet_definitions_path "$defs_store")" <<'YAML'
# ONLY exceptions live here. No entry means the logical name IS the concrete
# name — true for most things (jq, yq, gh, ripgrep, most plugins).
packages:
  jj:
    homebrew: jj
    winget: jj-vcs.jj
    apt: unavailable      # not packaged; ensure alerts, never guesses

  tailscale:
    homebrew:
      name: tailscale
      cask: true          # map form when there is more to say

  postgresql@16:
    version: "16.4"
    homebrew: postgresql@16
    winget: {name: PostgreSQL.PostgreSQL, version: "16.4"}

  terraform:
    version: 1.9.8

  node@24:
    homebrew: node@24
    winget: OpenJS.NodeJS.LTS
  node@26:
    homebrew: node@26
    winget: OpenJS.NodeJS

  # A Windows-only manager key costs the macOS hosts nothing.
  ripgrep:
    scoop: ripgrep

plugins:
  railyard:
    marketplace: claire-local

skills:
  grilling:
    source: github:claire/grilling-skill

agents:
  triage-bot:
    source: github:claire/triage-bot-agent

hooks:
  commit-guard:
    source: github:claire/commit-guard
YAML
    defs=$(fleet_definitions_load "$defs_store")

    # B-4: definitions use the same scalar-plus-sorted-directory reader as
    # the other layers. Later files override one leaf without discarding the
    # earlier category or its unrelated entries.
    defs_dir_store="$defs_root/directory-store"
    mkdir -p "$defs_dir_store/definitions"
    cat >"$defs_dir_store/definitions.yaml" <<'YAML'
packages:
  jj:
    homebrew: root-jj
agents:
  scalar-only:
    source: github:claire/scalar-only
YAML
    cat >"$defs_dir_store/definitions/00-base.yaml" <<'YAML'
packages:
  jj:
    homebrew: base-jj
plugins:
  railyard:
    marketplace: claire-local
  # This sibling exists only in the earlier file; the later file must not
  # replace the whole packages.jj map while overriding its homebrew leaf.
  example:
    marketplace: claire-local
YAML
    cat >"$defs_dir_store/definitions/10-overrides.yaml" <<'YAML'
packages:
  jj:
    homebrew: final-jj
    winget: jj-vcs.jj
skills:
  grilling:
    source: github:claire/grilling-skill
YAML
    defs_dir=$(fleet_definitions_load "$defs_dir_store")
    [ "$(fleet_resolve_package "$defs_dir" jj homebrew | jq -r '.name')" = final-jj ] ||
      fail "scalar definitions.yaml or directory precedence was wrong"
    [ "$(fleet_resolve_package "$defs_dir" jj winget | jq -r '.name')" = jj-vcs.jj ] ||
      fail "a later definitions file did not override/add its package leaf"
    [ "$(fleet_resolve_surface "$defs_dir" plugins example | jq -r '.marketplace')" = claire-local ] ||
      fail "an earlier definitions sibling leaf was discarded"
    fleet_definition_items "$defs_dir" | grep -Fqx definitions.skills.grilling ||
      fail "a definitions directory item was not enumerated"
    fleet_definition_items "$defs_dir" | grep -Fqx definitions.plugins.railyard ||
      fail "an earlier definitions directory item was discarded"
    fleet_definition_items "$defs_dir" | grep -Fqx definitions.agents.scalar-only ||
      fail "a scalar-only definitions item was discarded"
    fleet_run_item_digests '{}' "$defs_dir_store" | \
      grep -Fq 'definitions.plugins.railyard ' ||
      fail "an earlier definitions directory item had no digest"
    fleet_run_item_digests '{}' "$defs_dir_store" | \
      grep -Fq 'definitions.agents.scalar-only ' ||
      fail "a scalar definitions item had no digest"
    fleet_run_file_items "$defs_dir_store/definitions/10-overrides.yaml" \
      definitions/10-overrides.yaml | grep -Fqx definitions.skills.grilling ||
      fail "a definitions directory file did not produce scoped definition items"
    ! fleet_run_file_items "$defs_dir_store/definitions/10-overrides.yaml" \
      definitions/nested/file.yaml >/dev/null ||
      fail "a nested definitions path was treated as a direct child"
    ! fleet_run_layer_path definitions/.hidden.yaml ||
      fail "a hidden definitions file was treated as a layer"
    ! fleet_run_file_items "$defs_dir_store/definitions/10-overrides.yaml" \
      definitions/.hidden.yaml >/dev/null ||
      fail "a hidden definitions file was treated as an item source"
    ! fleet_vcs_path_owner definitions/.hidden.yaml >/dev/null ||
      fail "a hidden definitions file was authorized for writes"
    printf '%s\n' 'packages:' '  payload: enabled' \
      >"$defs_dir_store/groups-definitions.yaml"
    fleet_run_file_items "$defs_dir_store/groups-definitions.yaml" \
      groups/definitions/packages.yaml | grep -Fqx packages.payload ||
      fail "a group named definitions was misclassified as the definitions tier"
    ! fleet_run_file_items "$defs_dir_store/groups-definitions.yaml" \
      groups/definitions/packages.yaml | grep -Fq definitions. ||
      fail "a nested group definitions path crossed the definitions namespace"
    ! fleet_upstream_id_valid ../hosts ||
      fail "a traversal-shaped marketplace was accepted as an upstream id"

    defs_adversarial_store="$defs_root/store with * glob"
    mkdir -p "$defs_adversarial_store/definitions"
    cat >"$defs_adversarial_store/definitions/00-base.yaml" <<'YAML'
packages:
  jq:
    homebrew: jq
YAML
    defs_adversarial=$(fleet_definitions_load "$defs_adversarial_store")
    [ "$(fleet_resolve_package "$defs_adversarial" jq homebrew | jq -r '.name')" = jq ] ||
      fail "a definitions directory path with spaces/globs was not preserved"

    # --- the default rule, and the two entry forms ---
    [ "$(fleet_resolve_package "$defs" gh homebrew | jq -r '.name')" = gh ] ||
      fail "a package with no entry did not fall through to the default rule"
    [ "$(fleet_resolve_package "$defs" jj homebrew | jq -r '.name')" = jj ] ||
      fail "the scalar form of a per-manager entry did not resolve"
    [ "$(fleet_resolve_package "$defs" jj winget | jq -r '.name')" = jj-vcs.jj ] ||
      fail "a divergent per-manager name did not resolve"
    [ "$(fleet_resolve_package "$defs" tailscale homebrew |
      jq -Sc '{name, attributes}')" = '{"attributes":{"cask":true},"name":"tailscale"}' ] ||
      fail "the map form did not carry its attributes through to the manager"
    # An unknown attribute is passed through, so a new install flag needs no
    # reader change.
    [ "$(fleet_resolve_package "$defs" ripgrep scoop | jq -r '.name')" = ripgrep ] ||
      fail "a manager-specific entry did not resolve on the manager that has it"
    # ...and a manager key the host does not have is ignored rather than fatal.
    [ "$(fleet_resolve_package "$defs" ripgrep homebrew | jq -r '.name')" = ripgrep ] ||
      fail "a manager key the host lacks was not ignored"

    # --- `unavailable`: held with an alert naming the managers tried ---
    defs_hold=$(fleet_resolve_package "$defs" jj apt) && defs_rc=0 || defs_rc=$?
    [ "$defs_rc" -eq 75 ] ||
      fail "an unavailable package did not hold"
    [ "$(printf '%s\n' "$defs_hold" | jq -r '.resolved')" = false ] ||
      fail "an unavailable package reported itself resolved"
    [ "$(printf '%s\n' "$defs_hold" | jq -c '.managers_tried')" = '["apt"]' ] ||
      fail "the hold did not name every manager tried"
    printf '%s\n' "$defs_hold" | jq -r '.item' | grep -Fqx packages.jj ||
      fail "the hold did not name the logical package"
    # The first manager that resolves wins, in the host's own list order.
    [ "$(fleet_resolve_package "$defs" jj apt homebrew | jq -r '.manager')" = homebrew ] ||
      fail "resolution stopped at the first unavailable manager"

    # --- §5.1.2 streams are two logical names, and no new mechanism ---
    [ "$(fleet_resolve_package "$defs" node@24 homebrew | jq -r '.name')" = node@24 ] &&
      [ "$(fleet_resolve_package "$defs" node@26 homebrew | jq -r '.name')" = node@26 ] ||
      fail "two version streams did not resolve as two independent logical names"
    [ "$(fleet_resolve_package "$defs" node@24 winget | jq -r '.name')" = OpenJS.NodeJS.LTS ] ||
      fail "a stream did not map per manager"

    # --- §5.1.1 pins: enforced where expressible, refused where not ---
    # `latest` is the default and is never written down: an unpinned package
    # carries no version and fleet-update keeps it current.
    [ "$(fleet_resolve_package "$defs" jj homebrew | jq -r '.version')" = null ] ||
      fail "an unpinned package acquired a version"
    ! fleet_package_pinned "$defs" jj ||
      fail "an unpinned package reported itself pinned to fleet-update"
    fleet_package_pinned "$defs" terraform ||
      fail "a fleet-wide version pin was not visible to fleet-update"
    fleet_package_pinned "$defs" postgresql@16 ||
      fail "a per-manager version pin was not visible to fleet-update"
    ! fleet_package_pinned "$defs" nosuchpackage ||
      fail "a package with no entry at all reported itself pinned"

    # winget can select an exact version at install time, so the pin is
    # applied and fleet-update skips it.
    [ "$(fleet_resolve_package "$defs" postgresql@16 winget | jq -r '.pin')" = flag ] ||
      fail "an expressible pin was not enforced through the manager's own flag"

    # Homebrew is on the REFUSING side: `brew install` has no --version flag,
    # and `brew pin` only prevents a later upgrade of whatever is already
    # installed. A pin resolves only when <name>@<version> is a real formula.
    defs_brew_bin="$tmp/definitions/brew-bin"
    mkdir -p "$defs_brew_bin"
    cat >"$defs_brew_bin/brew" <<'SH'
#!/usr/bin/env bash
# Stub, never the real brew: answers the formula-existence probe only.
[ "${1:-}" = info ] && [ "${2:-}" = --json=v2 ] || exit 64
printf '%s\n' "$3" >>"$BREW_PROBE_LOG"
case ${3:-} in
  node@24 | node@26 | postgresql@16) printf '{"formulae":[{"name":"%s"}]}\n' "$3" ;;
  *) printf 'Error: No available formula with the name "%s".\n' "$3" >&2; exit 1 ;;
esac
SH
    chmod +x "$defs_brew_bin/brew"
    export BREW_PROBE_LOG="$tmp/definitions/brew-probes"
    : >"$BREW_PROBE_LOG"

    defs_pinned=$(PATH="$defs_brew_bin:$PATH" fleet_resolve_package "$defs" postgresql@16 homebrew)
    [ "$(printf '%s\n' "$defs_pinned" | jq -r '.name')" = postgresql@16 ] &&
      [ "$(printf '%s\n' "$defs_pinned" | jq -r '.pin')" = formula ] ||
      fail "a homebrew pin backed by a real formula did not resolve"
    grep -Fqx postgresql@16 "$BREW_PROBE_LOG" ||
      fail "the homebrew pin resolved without probing for the formula"

    # The draft's own worked example of a silent degrade: terraform 1.9.8 has
    # no formula, so the pin is refused exactly like `unavailable`.
    : >"$BREW_PROBE_LOG"
    defs_hold=$(PATH="$defs_brew_bin:$PATH" fleet_resolve_package "$defs" terraform homebrew) &&
      defs_rc=0 || defs_rc=$?
    [ "$defs_rc" -eq 75 ] ||
      fail "a homebrew pin with no matching formula silently degraded"
    grep -Fqx terraform@1.9.8 "$BREW_PROBE_LOG" ||
      fail "the refused pin was decided without probing <name>@<version>"
    printf '%s\n' "$defs_hold" | jq -r '.detail' | grep -Fq 1.9.8 ||
      fail "the pin hold did not name the requested version"

    # A host that cannot ANSWER the question holds too: never a guess.
    defs_hold=$(PATH=/usr/bin:/bin fleet_resolve_package "$defs" postgresql@16 homebrew) &&
      defs_rc=0 || defs_rc=$?
    [ "$defs_rc" -eq 75 ] ||
      fail "a host with no brew resolved a homebrew pin it could not verify"

    # --- the reserved definitions. namespace ---
    fleet_definition_items "$defs" | grep -Fqx definitions.packages.jj ||
      fail "a definition did not enumerate as an item under its own namespace"
    fleet_definition_items "$defs" | grep -Fqx definitions.hooks.commit-guard ||
      fail "a hooks definition did not enumerate as an item"
    ! fleet_definition_items "$defs" | grep -Fqx packages.jj ||
      fail "a definition enumerated under the desired-state item id"

    # …AND IT IS WIRED. The function above was correct and had no caller
    # outside this file, so `definitions.*` items had no digest, no verdict, no
    # §8.3 hold entry and no §7.7 narrow-hold entry — which made rule 6's
    # deliberately-narrow hold set EMPTY for a definitions-only commit. This
    # asserts the composition the run actually uses, not the helper alone.
    # Its own store: the shared fixture's definitions.yaml is asserted on
    # further down, and clobbering it here would make that assertion pass or
    # fail for the wrong reason.
    defs_univ="$defs_root/universe"
    mkdir -p "$defs_univ/hosts"
    printf 'packages:\n  jj: {homebrew: jj}\nskills:\n  grilling: {source: https://example.invalid/r}\n' \
      >"$defs_univ/definitions.yaml"
    printf 'platform: macos\ngroups: []\npackages:\n  jj: enabled\nskills:\n  grilling: enabled\n' \
      >"$defs_univ/hosts/probe.yaml"
    fleet_run_item_digests "$(fleet_fold "$defs_univ" probe)" "$defs_univ" \
      >"$defs_root/digests"
    for defs_expect in packages.jj skills.grilling definitions.packages.jj \
      definitions.skills.grilling; do
      awk -v i="$defs_expect" '$1 == i { f = 1 } END { exit(f ? 0 : 1) }' \
        "$defs_root/digests" ||
        fail "$defs_expect is missing from the run's item universe: $(tr '\n' ';' <"$defs_root/digests")"
    done
    # The two namespaces digest DIFFERENTLY, which is what keeps them from
    # sharing one verdict key and one applied/<host>.yaml entry.
    [ "$(awk '$1 == "packages.jj" { print $2 }' "$defs_root/digests")" != \
      "$(awk '$1 == "definitions.packages.jj" { print $2 }' "$defs_root/digests")" ] ||
      fail "the desired item and its definition share a digest"

    # And a FILE-scoped refusal of definitions.yaml holds the DEFINITIONS, not
    # the coincidentally same-named desired items.
    fleet_run_file_items "$defs_univ/definitions.yaml" definitions.yaml \
      >"$defs_root/file-items"
    grep -Fqx definitions.packages.jj "$defs_root/file-items" ||
      fail "a refusal of definitions.yaml did not hold the definition item"
    ! grep -Fqx packages.jj "$defs_root/file-items" ||
      fail "a refusal of definitions.yaml held the DESIRED item of the same name"
    # A layer file with no map-valued top-level key contributes NOTHING — yq's
    # `as` binding evaluates its body once on an empty stream and emitted a
    # bare `.` into every file-scoped hold set.
    printf 'platform: macos\n' >"$defs_root/facts-only.yaml"
    [ -z "$(fleet_run_file_items "$defs_root/facts-only.yaml" hosts/x.yaml)" ] ||
      fail "a facts-only layer file contributed a bogus item id"

    # A definition change does NOT invalidate the verdict on a desired item
    # that references it: the desired value is still `enabled`, and §7.2's
    # digest is insensitive to which layer supplied it. What surfaces the
    # change is the definition's OWN review.
    printf 'platform: macos\ngroups: []\npackages:\n  jj: enabled\n' \
      >"$defs_store/hosts/probe.yaml"
    defs_before=$(fleet_item_digest "$(fleet_fold "$defs_store" probe)" packages.jj)
    sed 's/winget: jj-vcs.jj/winget: jj-vcs.jj-next/' \
      "$(fleet_definitions_path "$defs_store")" >"$defs_store/definitions.next"
    mv "$defs_store/definitions.next" "$(fleet_definitions_path "$defs_store")"
    [ "$(fleet_item_digest "$(fleet_fold "$defs_store" probe)" packages.jj)" = "$defs_before" ] ||
      fail "editing a definition invalidated the desired item's verdict"
    defs=$(fleet_definitions_load "$defs_store")
    [ "$(fleet_resolve_package "$defs" jj winget | jq -r '.name')" = jj-vcs.jj-next ] ||
      fail "the edited definition did not change the concrete resolution"

    # --- §5.1.3 the four agent-surface categories, two delivery forms ---
    # Plugin-qualified: the plugin is the unit of install, so the member needs
    # no definition of its own.
    for defs_category in skills agents hooks; do
      defs_surface=$(fleet_resolve_surface "$defs" "$defs_category" superpowers/brainstorming)
      [ "$(printf '%s\n' "$defs_surface" | jq -r '.delivery')" = plugin ] ||
        fail "a plugin-qualified $defs_category name did not resolve through its plugin"
      [ "$(printf '%s\n' "$defs_surface" | jq -r '.plugin')" = superpowers ] &&
        [ "$(printf '%s\n' "$defs_surface" | jq -r '.member')" = brainstorming ] ||
        fail "a plugin-qualified $defs_category name did not split into plugin and member"
    done
    # Bare: standalone by definition.
    [ "$(fleet_resolve_surface "$defs" skills grilling | jq -r '.source')" = \
      github:claire/grilling-skill ] ||
      fail "a standalone skill did not resolve through its definition's source"
    [ "$(fleet_resolve_surface "$defs" agents triage-bot | jq -r '.delivery')" = standalone ] ||
      fail "a bare agent name was not standalone"
    # Plugins resolve through a marketplace, and no entry means the harness's
    # own default rather than a config key this design invents.
    [ "$(fleet_resolve_surface "$defs" plugins railyard | jq -r '.marketplace')" = claire-local ] ||
      fail "a non-default marketplace did not resolve"
    [ "$(fleet_resolve_surface "$defs" plugins ponytail | jq -r '.marketplace')" = null ] ||
      fail "a plugin with no entry did not fall through to the default marketplace"
    # A standalone skill with no entry falls back to the skill roots the
    # shipped collector already walks.
    [ "$(fleet_resolve_surface "$defs" agents nosuch | jq -r '.source')" = \
      "$HOME/.claude/agents/nosuch.md" ] ||
      fail "a standalone agent with no entry did not fall back to the user scope"

    # --- hooks resolve like everything else; TRUST is a separate question ---
    # `hooks` was a held CATEGORY until the §5.1.3 trust gate was
    # re-implemented. It is now gated per item (fleet_hook_trust, exercised in
    # tests/75-guards.sh), so no category is held outright and resolution says
    # nothing about whether a hook may run.
    for defs_category in packages plugins skills agents hooks mcp_servers \
      config_files projects; do
      ! fleet_category_held "$defs_category" ||
        fail "the $defs_category category is held outright with no member left in the set"
    done
    defs_surface=$(fleet_resolve_surface "$defs" hooks commit-guard)
    [ "$(printf '%s\n' "$defs_surface" | jq -r '.source')" = github:claire/commit-guard ] ||
      fail "a standalone hook did not resolve through its definition"
    [ "$(printf '%s\n' "$defs_surface" | jq -r '.delivery')" = standalone ] ||
      fail "a bare hook name did not resolve as standalone"
    [ "$(fleet_resolve_surface "$defs" hooks ponytail/session-start | jq -r '.plugin')" = ponytail ] ||
      fail "a plugin-qualified hook did not resolve to its plugin"
    for defs_category in hooks plugins; do
      [ "$(fleet_resolve_surface "$defs" "$defs_category" ponytail | jq -r '.held')" = false ] ||
        fail "$defs_category still carries a category-held marker"
    done

    # --- ensure-tools ---
    # Silent test-and-install through the host's USER-SPACE manager, reading
    # the same definitions.yaml as everything else. No sudo, ever.
    #
    # The prerequisite list is substituted for two synthetic names, because
    # whether /usr/bin ships tmux differs by runner image and a fixture that
    # turns on that is a fixture that passes for the wrong reason. One of the
    # two has a definition and one has none, so both the mapping and the
    # default rule are exercised on the bootstrap path.
    defs_ensure_store="$tmp/definitions/ensure-store"
    mkdir -p "$defs_ensure_store"
    cat >"$(fleet_definitions_path "$defs_ensure_store")" <<'YAML'
packages:
  fleet-fixture-tool-a:
    homebrew: mapped-tool-a
YAML
    export ROUNDHOUSE_ENSURE_TOOLS='jq yq fleet-fixture-tool-a fleet-fixture-tool-b'
    defs_bin="$tmp/definitions/ensure-bin"
    mkdir -p "$defs_bin"
    export BREW_INSTALL_LOG="$tmp/definitions/brew-installs"
    export SUDO_LOG="$tmp/definitions/sudo-invocations"
    : >"$BREW_INSTALL_LOG"
    : >"$SUDO_LOG"
    cat >"$defs_bin/brew" <<'SH'
#!/usr/bin/env bash
case ${1:-} in
  install) shift; printf '%s\n' "$*" >>"$BREW_INSTALL_LOG" ;;
  info) exit 1 ;;
  *) exit 64 ;;
esac
SH
    cat >"$defs_bin/sudo" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SUDO_LOG"
exit 1
SH
    chmod +x "$defs_bin/brew" "$defs_bin/sudo"

    defs_out=$(PATH="$defs_bin:$PATH" ROUNDHOUSE_FLEET_STORE="$defs_ensure_store" \
      "$cli" ensure-tools 2>&1) ||
      fail "ensure-tools failed on a host whose manager can install everything"
    [ -z "$defs_out" ] ||
      fail "ensure-tools was not silent on success: $defs_out"
    grep -Fqx mapped-tool-a "$BREW_INSTALL_LOG" ||
      fail "ensure-tools did not install a prerequisite through its definition"
    grep -Fqx fleet-fixture-tool-b "$BREW_INSTALL_LOG" ||
      fail "ensure-tools did not fall back to the default rule for an undefined prerequisite"
    ! grep -Fqx jq "$BREW_INSTALL_LOG" ||
      fail "ensure-tools reinstalled a prerequisite that was already present"
    [ ! -s "$SUDO_LOG" ] ||
      fail "ensure-tools escalated privilege"

    # A host with no user-space manager cannot get there, and that is the one
    # outcome a human has to act on: loud, naming what is missing. apt is
    # deliberately not a user-space manager — installing through it needs
    # root, and a bootstrap that escalates to fetch a YAML parser is one
    # nobody can run unattended.
    : >"$BREW_INSTALL_LOG"
    defs_bare="$tmp/definitions/bare-bin"
    mkdir -p "$defs_bare"
    cat >"$defs_bare/apt-get" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$defs_bare/apt-get"
    # A sanitized PATH with no homebrew, winget or scoop anywhere on it. yq
    # is missing here too, which is the fresh-host case §5.1 names: the
    # bootstrap falls back to the default rule rather than refusing to read.
    defs_out=$(PATH="$defs_bare:/usr/bin:/bin" ROUNDHOUSE_FLEET_STORE="$defs_ensure_store" \
      "$cli" ensure-tools 2>&1) && defs_rc=0 || defs_rc=$?
    [ "$defs_rc" -ne 0 ] ||
      fail "ensure-tools reported success on a host that cannot install anything"
    printf '%s\n' "$defs_out" | grep -Fq fleet-fixture-tool-a ||
      fail "the ensure-tools hold did not name the missing prerequisite"
    printf '%s\n' "$defs_out" | grep -Fq sudo ||
      fail "the ensure-tools hold did not say roundhouse never uses sudo"
    [ ! -s "$BREW_INSTALL_LOG" ] ||
      fail "ensure-tools installed something after reporting it could not"

    # Nothing missing is nothing done, silently.
    defs_out=$(ROUNDHOUSE_ENSURE_TOOLS='jq yq' \
      ROUNDHOUSE_FLEET_STORE="$defs_ensure_store" "$cli" ensure-tools 2>&1) ||
      fail "ensure-tools failed with every prerequisite already present"
    [ -z "$defs_out" ] ||
      fail "ensure-tools spoke when there was nothing to do"

    # The list override is a TEST hook and is inert on a real host: without
    # the suite's own kill-switch the shipped prerequisite set is what runs.
    [ "$(unset ROUNDHOUSE_SELFTEST
      ROUNDHOUSE_ENSURE_TOOLS='nothing-at-all' fleet_ensure_tools | tr '\n' ' ')" = \
      'jq yq jj tmux ' ] ||
      fail "the ensure-tools list override was not inert without ROUNDHOUSE_SELFTEST"
  )
fi

"$cli" 2>&1 | grep -Fq 'roundhouse ensure-tools' ||
  fail "ensure-tools is not in the usage banner"
grep -qE '^  ensure-tools\)' "$cli" ||
  fail "ensure-tools is not dispatched by the entrypoint"
