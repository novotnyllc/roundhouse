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
    # Walk every row of the owner table, for this host and a peer, and require
    # the filter to keep exactly the paths the table does not give to vireo.
    for pub_path in fleet.yaml definitions.yaml definitions/10-x.yaml \
      fleet/agent-plugins.yaml os/macos.yaml groups/dev.yaml hosts/vireo.yaml \
      hosts/vireo/skills.yaml lineage/1-x.yaml proposals/p.yaml \
      trust/signers.yaml checkpoints/c.yaml joins/vireo.yaml \
      journal/vireo/2026-08-07.yaml journal/vireo/deep/x.yaml journal/wren/d.yaml \
      journal/vireo journal/vireo/ alerts/vireo/x.yaml alerts/wren/x.yaml \
      alerts/vireo findings/vireo/x.yaml findings/wren/x.yaml \
      applied/vireo.yaml applied/wren.yaml applied/vireo/x.yaml \
      upstreams/m/vireo.yaml upstreams/m/wren.yaml upstreams/m/deep/vireo.yaml \
      upstreams/vireo.yaml README.md .gitignore vireo; do
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
    done
  )
fi
