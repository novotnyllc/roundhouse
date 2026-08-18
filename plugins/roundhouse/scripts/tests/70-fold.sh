# roundhouse self-check — §4's fold: four layers, the knockout pass, the value
# digest, categories, config-key ownership, provenance and the ssh render.
#
# No jj and no store repository: pure yq/jq over file fixtures, which is the
# seam §12.1 draws and the reason these fixtures are affordable. They cover
# the parts of the design most likely to be wrong.
#
# Sourced by scripts/test-roundhouse in a fixed order; not a
# standalone test file. See that driver for why.
# shellcheck shell=bash

if [ -z "$fleet_fixture_yq" ]; then
  printf '\n'
  printf '========================================================================\n'
  printf 'NOTICE: fold / definitions / records fixtures skipped\n'
  printf '  required: yq   found: none\n'
  printf '  §4 the fold, §5.1 definitions and §10 record shapes are UNVERIFIED.\n'
  printf '  Run this suite once on a yq-equipped host before merge.\n'
  printf '========================================================================\n'
  printf '\n'
else
  printf 'fold: §4 layers, knockout, digest, categories (yq %s)\n' \
    "$("$fleet_fixture_yq" --version | awk '{print $NF}')"
  (
    set -eu
    PATH=$fleet_fixture_path
    export PATH
    # shellcheck source=/dev/null
    ROUNDHOUSE_LIB_ONLY=1 . "$cli"

    fold_store="$tmp/fold/store"
    mkdir -p "$fold_store/os" "$fold_store/groups" "$fold_store/hosts/wren" \
      "$fold_store/fleet"

    # --- the four layers, file form ---
    cat >"$fold_store/fleet.yaml" <<'YAML'
# Applies to every host unless a narrower layer says otherwise.
policy:
  cadence_hours: 12
  canary_group: canary
  canary_wait_hours: 24

plugins:
  ponytail: enabled
  legal: enabled
  railyard: enabled

config_files:
  ~/.claude/settings.json:
    keys:
      env.DISABLE_TELEMETRY: managed
      model: unmanaged
    never:
      - env.ANTHROPIC_API_KEY
YAML
    cat >"$fold_store/os/macos.yaml" <<'YAML'
packages:
  jq: enabled
  jj: enabled
plugins:
  impeccable: enabled
YAML
    cat >"$fold_store/groups/development.yaml" <<'YAML'
plugins:
  railyard: enabled
  impeccable: disabled
skills:
  tdd: enabled
YAML
    cat >"$fold_store/groups/canary.yaml" <<'YAML'
# Deliberately carries no desired state. An empty document is "no opinion".
YAML
    cat >"$fold_store/hosts/vireo.yaml" <<'YAML'
platform: macos
hostname: vireo.local
tailnet_name: vireo.tail1234.ts.net
user: claire
package_managers: [homebrew]
groups: [development, canary]

plugins:
  legal: absent
  railyard:
    state: enabled
    marketplace: claire-local

config_files:
  ~/.claude/settings.json:
    keys:
      permissions.deny: managed
      # A LEGITIMATE string "absent", nested inside a config_files value. The
      # knockout is scoped to item position and must never reach this.
      ui.theme: absent
YAML
    fold_vireo=$(fleet_fold "$fold_store" vireo)

    # Layer order, low to high, and the group order is the HOST's list order.
    [ "$(fleet_layer_files "$fold_store" vireo | sed -e "s#^$fold_store/##" | tr '\n' ' ')" = \
      'fleet.yaml os/macos.yaml groups/development.yaml groups/canary.yaml hosts/vireo.yaml ' ] ||
      fail "the fold's layer order is not fleet < os < groups (host order) < hosts"

    # os/ wins over fleet.yaml, groups win over os, and the host wins over all.
    [ "$(printf '%s\n' "$fold_vireo" | jq -r '.plugins.impeccable')" = disabled ] ||
      fail "a group layer did not replace the os layer's value"
    [ "$(printf '%s\n' "$fold_vireo" | jq -r '.packages.jj')" = enabled ] ||
      fail "the os layer did not contribute to the fold"
    [ "$(printf '%s\n' "$fold_vireo" | jq -r '.skills.tdd')" = enabled ] ||
      fail "a group layer did not contribute to the fold"

    # map + map deep merges key by key; anything else is replaced whole by the
    # higher layer.
    [ "$(printf '%s\n' "$fold_vireo" | jq -Sc '.plugins.railyard')" = \
      '{"marketplace":"claire-local","state":"enabled"}' ] ||
      fail "the host layer's map form did not replace the lower layers' scalar"
    [ "$(printf '%s\n' "$fold_vireo" | jq -r '.plugins.ponytail')" = enabled ] ||
      fail "an item nothing overrode did not survive the fold"

    # The knockout: scoped to <category>.<item>, and never recursive.
    [ "$(printf '%s\n' "$fold_vireo" | jq -r '.plugins | has("legal")')" = false ] ||
      fail "a scalar absent at item position did not knock the item out"
    [ "$(printf '%s\n' "$fold_vireo" |
      jq -r '.config_files["~/.claude/settings.json"].keys["ui.theme"]')" = absent ] ||
      fail "the knockout pass deleted a legitimate nested string \"absent\""

    # An empty document is "no opinion" and contributes nothing.
    [ "$(printf '%s\n' "$fold_vireo" | jq -r '.plugins.railyard.state')" = enabled ] ||
      fail "an empty group document did not fold as no opinion"

    # …and so is a null VALUE, which is a different thing and was untested.
    # §4:416 — "no opinion at this layer; skip it". A truncated line in a
    # narrower layer (`  ponytail:` with nothing after it) overwrote the item
    # with null instead: `fleet_item_digest` then returned 1 on the empty
    # value so the item never reached the verdict list, and the run's removal
    # loop read "no value in the fold" as "gone from the layers" — pruning it
    # from applied/ and journaling a FALSE `outcome: reverted` that every peer
    # reasons from through §8.2b rule 4 and §10.8's revert signature.
    printf 'platform: macos\ngroups: [development]\nplugins:\n  ponytail:\n' \
      >"$fold_store/hosts/null-probe.yaml"
    fold_null=$(fleet_fold "$fold_store" null-probe)
    [ "$(printf '%s\n' "$fold_null" | jq -r '.plugins.ponytail')" = enabled ] ||
      fail "a null item value overwrote a lower layer instead of reading as no opinion"
    [ -n "$(fleet_item_digest "$fold_null" plugins.ponytail)" ] ||
      fail "an item a null value shadowed produced no digest, so it never reaches a verdict"
    # The nested case still survives: a null INSIDE a value is data, exactly as
    # a nested literal "absent" is.
    printf 'config_files:\n  ~/.probe.json:\n    keys:\n      ui.theme: null\n' \
      >>"$fold_store/hosts/null-probe.yaml"
    [ "$(fleet_fold "$fold_store" null-probe |
      jq -r '.config_files["~/.probe.json"].keys | has("ui.theme")')" = true ] ||
      fail "the null drop reached inside a value and deleted legitimate data"
    rm -f "$fold_store/hosts/null-probe.yaml"

    # …and a null CATEGORY is the same "no opinion" one grain coarser: a
    # truncated `plugins:` (nothing after it) in the host layer must not null
    # the whole category the lower layers filled. `fleet_unknown_categories`
    # does not catch it (the name is KNOWN, only the value is non-map), so
    # nothing else held it and `*d` overwrote every plugin fleet-wide with null,
    # emitting a false `outcome: reverted` for each. The item-level drop above
    # rewrote only entries INSIDE a map value, so a top-level `!!null` survived.
    printf 'platform: macos\ngroups: [development]\nplugins:\n' \
      >"$fold_store/hosts/nullcat-probe.yaml"
    [ "$(fleet_fold "$fold_store" nullcat-probe | jq -r '.plugins.ponytail')" = enabled ] ||
      fail "a null category value erased the category the lower layers filled"
    rm -f "$fold_store/hosts/nullcat-probe.yaml"

    # --- group precedence follows the host's list, in both directions ---
    # Two groups that disagree about one item. There is no priority field, no
    # alphabetical rule and no hiera.yaml: the answer is in the file the
    # operator already has open.
    cat >"$fold_store/groups/loud.yaml" <<'YAML'
skills:
  tdd: disabled
YAML
    for fold_order in 'development, loud' 'loud, development'; do
      printf 'platform: macos\ngroups: [%s]\n' "$fold_order" \
        >"$fold_store/hosts/order-probe.yaml"
      fold_last=${fold_order##*, }
      fold_expect=enabled
      [ "$fold_last" != loud ] || fold_expect=disabled
      [ "$(fleet_fold "$fold_store" order-probe | jq -r '.skills.tdd')" = "$fold_expect" ] ||
        fail "group precedence ignored the host's own list order ($fold_order)"
    done
    rm -f "$fold_store/hosts/order-probe.yaml" "$fold_store/groups/loud.yaml"

    # --- directory form at every tier ---
    # `hosts/wren/` — one host split because one file got long, merged in
    # filename order and then folded as layer 4.
    cat >"$fold_store/hosts/wren/host.yaml" <<'YAML'
platform: macos
hostname: wren.local
user: claire
package_managers: [homebrew]
groups: [development]
YAML
    cat >"$fold_store/hosts/wren/plugins.yaml" <<'YAML'
plugins:
  impeccable: enabled
YAML
    cat >"$fold_store/hosts/wren/skills.yaml" <<'YAML'
skills:
  ponytail-audit: enabled
YAML
    [ "$(fleet_tier_files "$fold_store" hosts/wren | tr '\n' ' ')" = \
      "$fold_store/hosts/wren/host.yaml $fold_store/hosts/wren/plugins.yaml $fold_store/hosts/wren/skills.yaml " ] ||
      fail "a directory-form tier was not merged in filename order"
    fold_wren=$(fleet_fold "$fold_store" wren)
    [ "$(printf '%s\n' "$fold_wren" | jq -r '.plugins.impeccable')" = enabled ] ||
      fail "the directory form of the host tier did not win over the group layer"
    [ "$(printf '%s\n' "$fold_wren" | jq -r '.skills["ponytail-audit"]')" = enabled ] ||
      fail "a second file in a directory-form tier did not fold"

    # The same split at the fleet tier: file form and directory form coexist,
    # and the file sorts first.
    cat >"$fold_store/fleet/late.yaml" <<'YAML'
plugins:
  ponytail: disabled
YAML
    [ "$(fleet_tier_files "$fold_store" fleet | tr '\n' ' ')" = \
      "$fold_store/fleet.yaml $fold_store/fleet/late.yaml " ] ||
      fail "fleet.yaml did not sort before fleet/*.yaml in the same tier"
    [ "$(fleet_fold "$fold_store" wren | jq -r '.plugins.ponytail')" = disabled ] ||
      fail "the directory form of the fleet tier did not fold"
    rm -f "$fold_store/fleet/late.yaml"

    # A tier with no file at all is no opinion, not an error: a fresh store
    # has no os/ file for a platform nobody has enrolled yet.
    [ "$(fleet_fold_files)" = '{}' ] ||
      fail "the fold over no layer files was not an empty document"

    # --- §7.2 the value digest ---
    # Identical documents saved CRLF and LF must digest identically: with a
    # Windows editor in the fleet, byte-binding re-reviews the world on a
    # line-ending default.
    printf 'plugins:\n  ponytail: enabled\n' >"$fold_store/hosts/lf.yaml"
    printf 'plugins:\r\n  ponytail: enabled\r\n' >"$fold_store/hosts/crlf.yaml"
    fold_lf=$(fleet_item_digest "$(fleet_fold "$fold_store" lf)" plugins.ponytail)
    fold_crlf=$(fleet_item_digest "$(fleet_fold "$fold_store" crlf)" plugins.ponytail)
    [ "$fold_lf" = "$fold_crlf" ] ||
      fail "CRLF and LF forms of the same document produced different digests"
    printf '%s\n' "$fold_lf" | grep -qE '^[0-9a-f]{64}$' ||
      fail "the value digest is not a lowercase sha256"

    # Scalar and map forms are the same item AT THE DIGEST LAYER too.
    [ "$(printf 'enabled\n' | fleet_value_digest plugins.ponytail)" = \
      "$(printf '{state: enabled}\n' | fleet_value_digest plugins.ponytail)" ] ||
      fail "the scalar and map forms of one value digested differently"
    # ...and the item id is bound into the digest, so two items with the same
    # value are still two items.
    [ "$(printf 'enabled\n' | fleet_value_digest plugins.ponytail)" != \
      "$(printf 'enabled\n' | fleet_value_digest packages.ponytail)" ] ||
      fail "the value digest ignored the item id"
    # ...including across the reserved definitions namespace, which is the
    # collision §5.1 exists to prevent.
    [ "$(printf 'enabled\n' | fleet_value_digest packages.jj)" != \
      "$(printf 'enabled\n' | fleet_value_digest definitions.packages.jj)" ] ||
      fail "a definition and its desired item shared one digest"

    # Promotion across layers changes no digest: lifting an item from three
    # host files up to fleet.yaml must trigger no review.
    printf 'plugins:\n  ponytail: enabled\n' >"$fold_store/hosts/promoted.yaml"
    [ "$(fleet_item_digest "$(fleet_fold "$fold_store" promoted)" plugins.ponytail)" = \
      "$fold_lf" ] || fail "promoting an item between layers changed its digest"
    rm -f "$fold_store/hosts/promoted.yaml" "$fold_store/hosts/lf.yaml" \
      "$fold_store/hosts/crlf.yaml"

    # YAML 1.1 coercion happens BEFORE the digest and is visible in it, and
    # the digest canonicalizes number form (12 and 12.0 are the same
    # value/item). Both are documented consequences, not bugs.
    [ "$(printf '{mode: 0755, flag: yes, toggle: on}\n' |
      yq -o=json -I=0 | jq -Sc "$fleet_value_normalize")" = \
      '{"flag":"yes","mode":755,"toggle":"on"}' ] ||
      fail "YAML 1.1 coercion did not reach the digest input unchanged"
    [ "$(printf '12\n' | fleet_value_digest policy.cadence_hours)" = \
      "$(printf '12.0\n' | fleet_value_digest policy.cadence_hours)" ] ||
      fail "12 and 12.0 did not digest identically (digest canonicalizes number form)"

    # --- item identity ---
    [ "$(fleet_item_split config_files.~/.claude/settings.json | tr '\n' '|')" = \
      'config_files|~/.claude/settings.json|' ] ||
      fail "the item split did not split on the first dot"
    [ "$(fleet_item_split definitions.packages.postgresql@16 | tr '\n' '|')" = \
      'definitions.packages|postgresql@16|' ] ||
      fail "the reserved definitions. prefix did not survive the item split"
    ! fleet_item_split plugins ||
      fail "a bare category parsed as an item id"
    [ "$(fleet_item_value "$fold_vireo" config_files.~/.claude/settings.json |
      jq -r '.keys["permissions.deny"]')" = managed ] ||
      fail "an item name carrying dots could not be read back out of the fold"

    # Host facts are facts, not items: they carry no digest and no verdict.
    fleet_items "$fold_vireo" | grep -Fqx plugins.ponytail ||
      fail "the item enumeration missed an item"
    ! fleet_items "$fold_vireo" | grep -q '^groups\.' ||
      fail "the item enumeration treated a host fact as an item"
    ! fleet_items "$fold_vireo" | grep -Fqx plugins.legal ||
      fail "a knocked-out item still enumerated"

    # --- §4's asymmetry: unknown key vs unknown category ---
    cat >"$fold_store/hosts/oddball.yaml" <<'YAML'
platform: macos
groups: []
plugins:
  ponytail:
    state: enabled
    some_future_flag: true
firmware:
  bios: enabled
YAML
    fold_oddball=$(fleet_fold "$fold_store" oddball)
    # Unknown key INSIDE a known item: ignored. It cannot under-converge.
    [ "$(printf '%s\n' "$fold_oddball" | jq -r '.plugins.ponytail.some_future_flag')" = true ] ||
      fail "an unknown key inside a known item did not survive the fold"
    [ "$(fleet_unknown_categories "$fold_oddball" | tr '\n' ' ')" = 'firmware ' ] ||
      fail "an unknown category was not named"
    [ -z "$(fleet_unknown_categories "$fold_vireo")" ] ||
      fail "a document of known categories and host facts reported an unknown one"
    rm -f "$fold_store/hosts/oddball.yaml"

    # An unrecognised directory at the store root is the same class of
    # finding: it may carry desired state nothing folded.
    mkdir -p "$fold_store/journal/vireo" "$fold_store/regions"
    [ "$(fleet_unknown_layer_dirs "$fold_store" | tr '\n' ' ')" = 'regions ' ] ||
      fail "an unrecognised layer directory was not named"
    rmdir "$fold_store/regions"

    # --- §5 config-key ownership: never beats managed, either direction ---
    [ -z "$(fleet_config_key_collisions "$fold_vireo")" ] ||
      fail "a clean config_files item reported a never/managed collision"
    cat >"$fold_store/hosts/greedy.yaml" <<'YAML'
platform: macos
groups: []
config_files:
  ~/.claude/settings.json:
    keys:
      # Longer than the excluded namespace...
      env.ANTHROPIC_API_KEY.value: managed
      # ...and shorter than it. `never` wins both ways.
      permissions: managed
      env.DISABLE_TELEMETRY: managed
    never:
      - env.ANTHROPIC_API_KEY
      - permissions.deny
YAML
    fold_greedy=$(fleet_config_key_collisions "$(fleet_fold "$fold_store" greedy)")
    [ "$(printf '%s\n' "$fold_greedy" | grep -c .)" -eq 2 ] ||
      fail "never/managed collisions were not caught in both prefix directions"
    printf '%s\n' "$fold_greedy" | grep -Fq 'env.ANTHROPIC_API_KEY.value' ||
      fail "a managed key under an excluded namespace was not refused"
    printf '%s\n' "$fold_greedy" | grep -Fq 'permissions' ||
      fail "a managed key that is a prefix of an excluded key was not refused"
    ! printf '%s\n' "$fold_greedy" | grep -Fq env.DISABLE_TELEMETRY ||
      fail "a disjoint managed key was refused as a collision"
    rm -f "$fold_store/hosts/greedy.yaml"

    # --- §5 chezmoi co-ownership: detected, never required ---
    # Absence is never an error, and it is never a hold either.
    [ -z "$(PATH=/usr/bin:/bin fleet_config_coowned "$fold_vireo")" ] ||
      fail "a host without chezmoi reported co-ownership"
    fold_chezmoi_bin="$tmp/fold/chezmoi-bin"
    mkdir -p "$fold_chezmoi_bin"
    cat >"$fold_chezmoi_bin/chezmoi" <<'SH'
#!/usr/bin/env bash
# Minimal source-state query: exits non-zero for a target it does not manage.
[ "${1:-}" = source-path ] && [ "${2:-}" = -- ] || exit 64
case ${3:-} in
  *"/.claude/settings.json") printf '%s\n' "$HOME/.local/share/chezmoi/dot_claude/settings.json" ;;
  *) exit 1 ;;
esac
SH
    chmod +x "$fold_chezmoi_bin/chezmoi"
    fold_coowned=$(PATH="$fold_chezmoi_bin:$PATH" fleet_config_coowned "$fold_vireo")
    [ "$(printf '%s\n' "$fold_coowned" | grep -c .)" -eq 2 ] ||
      fail "chezmoi co-ownership was not detected for every managed key in the file"
    printf '%s\n' "$fold_coowned" | grep -Fq 'permissions.deny' ||
      fail "the co-ownership report did not name the managed key"
    # An unmanaged key is not co-owned: roundhouse never claimed it.
    ! printf '%s\n' "$fold_coowned" | grep -Fq model ||
      fail "an unmanaged key was reported as co-owned"

    # --- §5 the rendered ssh config ---
    fold_ssh="$tmp/fold/ssh-config"
    fleet_ssh_config_render "$fold_store" "$fold_ssh" ||
      fail "the ssh render refused a clean store"
    grep -Fqx 'Host rh-vireo' "$fold_ssh" ||
      fail "the ssh render did not address the host as rh-<name>"
    grep -Fqx '  HostName vireo.tail1234.ts.net' "$fold_ssh" ||
      fail "the ssh render preferred hostname over tailnet_name"
    grep -Fqx '  HostName wren.local' "$fold_ssh" ||
      fail "the ssh render did not fall back to hostname without a tailnet name"
    ! grep -q ssh_alias "$fold_ssh" ||
      fail "the ssh render leaked a personal alias namespace into the store's file"
    [ "$(file_mode "$fold_ssh")" = 600 ] ||
      fail "the rendered ssh config is not owner-only"

    # A newline in a hand-authored field would inject ProxyCommand into a file
    # every fleet operation reads. Refuse the whole render; emit no partial.
    fold_ssh_hostile="$tmp/fold/ssh-config-hostile"
    cat >"$fold_store/hosts/hostile.yaml" <<'YAML'
platform: macos
user: claire
tailnet_name: "hostile.example\n  ProxyCommand touch /tmp/pwn"
groups: []
YAML
    ! fleet_ssh_config_render "$fold_store" "$fold_ssh_hostile" 2>/dev/null ||
      fail "the ssh render accepted a newline-bearing tailnet_name"
    [ ! -e "$fold_ssh_hostile" ] ||
      fail "a refused ssh render still wrote a partial file"
    rm -f "$fold_store/hosts/hostile.yaml"
    # The newline case is separate because it is the one a line-oriented
    # predicate silently passes: `grep -x` matches per line, so a value whose
    # FIRST line is well-formed reads as clean.
    ! fleet_validate_ssh_field "$(printf 'vireo.local\n  ProxyCommand touch /tmp/pwn')" ||
      fail "the ssh render field predicate accepted a value with a well-formed first line"
    for fold_field in '' '-oProxyCommand=x' 'has space' 'semi;colon' 'a/b'; do
      ! fleet_validate_ssh_field "$fold_field" ||
        fail "an ssh render field predicate accepted a hostile value: $fold_field"
    done
    for fold_field in vireo vireo.local vireo.tail1234.ts.net claire iris-wsl; do
      fleet_validate_ssh_field "$fold_field" ||
        fail "an ssh render field predicate refused a well-formed value: $fold_field"
    done

    # --- §4 provenance: file, never file:line ---
    fold_explain="$tmp/fold/explain"
    ROUNDHOUSE_FLEET_STORE="$fold_store" "$cli" fleet-explain vireo plugins.railyard \
      >"$fold_explain" 2>&1 || fail "fleet-explain failed on a resolvable item"
    [ "$(sed -n '1s/^plugins\.railyard = //p' "$fold_explain" | jq -Sc .)" = \
      '{"marketplace":"claire-local","state":"enabled"}' ] ||
      fail "fleet-explain did not print the resolved value"
    for fold_layer in fleet.yaml os/macos.yaml groups/development.yaml \
      groups/canary.yaml hosts/vireo.yaml; do
      grep -Fq "$fold_layer" "$fold_explain" ||
        fail "fleet-explain omitted the layer $fold_layer"
    done
    grep -qE '^  os/macos\.yaml +— +\(no opinion\)$' "$fold_explain" ||
      fail "fleet-explain did not report a layer with no opinion"
    assert_ordered "$fold_explain" 'fleet.yaml' 'hosts/vireo.yaml'
    [ "$(grep -c -- '<- wins' "$fold_explain")" -eq 1 ] ||
      fail "fleet-explain marked other than exactly one winning layer"
    grep -Fq 'hosts/vireo.yaml' "$fold_explain" &&
      grep -- '<- wins' "$fold_explain" | grep -Fq hosts/vireo.yaml ||
      fail "fleet-explain did not mark the highest opinionated layer as the winner"
    # Line numbers are DELIBERATELY absent: yq's `line` operator does not count
    # comment-only lines, so on a commented file every number it reports is
    # confidently wrong.
    ! grep -qE '\.yaml:[0-9]' "$fold_explain" ||
      fail "fleet-explain reported a line number"
    # One argument explains this host, two name it.
    ROUNDHOUSE_FLEET_STORE="$fold_store" "$cli" fleet-explain nosuchitem \
      >/dev/null 2>&1 && fail "fleet-explain accepted an id that is not <category>.<name>"
    ROUNDHOUSE_FLEET_STORE="$fold_store" "$cli" fleet-explain vireo plugins.legal \
      2>&1 | grep -Fq 'plugins.legal = <no opinion>' ||
      fail "fleet-explain did not report a knocked-out item as unresolved"
  )
fi

# The command is reachable, documented, and takes one or two arguments.
"$cli" 2>&1 | grep -Fq 'roundhouse fleet-explain' ||
  fail "fleet-explain is not in the usage banner"
grep -qE '^  fleet-explain\)' "$cli" ||
  fail "fleet-explain is not dispatched by the entrypoint"
