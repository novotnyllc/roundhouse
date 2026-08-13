# roundhouse self-check — §6/§6.1/§10 run driver: cadence and jitter, the
# apply layer's per-category answers, the evidence the §8.2b ladder decides
# on, seeding, and the push-nudge.
#
# No jj and no store repository: everything here is pure file and arithmetic
# logic, which is the seam §12.1 draws. The repository half of the run driver
# lives in tests/93-jj-run.sh.
#
# Sourced by scripts/test-roundhouse in a fixed order; not a
# standalone test file. See that driver for why.
# shellcheck shell=bash

if [ -n "$fleet_fixture_yq" ]; then
  printf 'run: §6.1 cadence, apply layer, evidence, seed, nudge\n'
  (
    set -eu
    PATH=$fleet_fixture_path
    export PATH
    # shellcheck source=/dev/null
    ROUNDHOUSE_LIB_ONLY=1 . "$cli"

    run_root="$tmp/run"
    run_store="$run_root/store"
    mkdir -p "$run_store/hosts" "$run_root/layers/hosts"
    ROUNDHOUSE_FLEET_STORE=$run_store
    HOME="$run_root/home"
    export ROUNDHOUSE_FLEET_STORE HOME
    mkdir -p "$HOME"

    # --- §6.1 the two cadences and the jitter that spreads them ---
    # Seeded from the host NAME. A fleet whose hosts re-roll their offset every
    # run converges on the same minute as often as it spreads out, and jitter
    # is this design's ONLY coordination primitive — there are no leases to
    # fall back on.
    [ "$(fleet_run_jitter vireo 11)" = "$(fleet_run_jitter vireo 11)" ] ||
      fail "the per-host jitter is not stable across calls"
    [ "$(fleet_run_jitter vireo 11)" != "$(fleet_run_jitter wren 11)" ] ||
      fail "two hosts drew the same jitter offset from the same span"
    for run_span_host in vireo wren corvid iris-wsl mac-studio; do
      run_offset=$(fleet_run_jitter "$run_span_host" 11)
      [ "$run_offset" -ge 0 ] && [ "$run_offset" -lt 11 ] ||
        fail "jitter left its span for $run_span_host: $run_offset"
    done
    [ "$(fleet_run_jitter vireo 0)" = 0 ] ||
      fail "a zero jitter span did not collapse to no offset"

    # Policy comes from the FOLD, never from a file on the box being governed:
    # zeroing a knob locally must not weaken a gate.
    run_policy='{"policy":{"fast_interval_minutes":20,"fast_jitter_minutes":5,
      "cadence_hours":12,"jitter_minutes":90}}'
    run_fast=$(fleet_run_interval_seconds "$run_policy" vireo fast)
    [ "$run_fast" -ge 900 ] && [ "$run_fast" -le 1500 ] ||
      fail "the fast interval left 20 ± 5 minutes: ${run_fast}s"
    run_full=$(fleet_run_interval_seconds "$run_policy" vireo full)
    [ "$run_full" -ge $(((720 - 90) * 60)) ] && [ "$run_full" -le $(((720 + 90) * 60)) ] ||
      fail "the full interval left 12h ± 90 minutes: ${run_full}s"
    # The defaults are the store's, so a fold with no policy: block still runs
    # on the design's own cadence rather than on nothing.
    [ -n "$(fleet_run_interval_seconds '{}' vireo fast)" ] ||
      fail "a fold carrying no policy block produced no fast interval"

    # --- which store paths the fold reads ---
    for run_layer in fleet.yaml definitions.yaml definitions/10-overrides.yaml os/macos.yaml \
      groups/development.yaml hosts/vireo.yaml hosts/wren/skills.yaml \
      fleet/policy.yaml; do
      fleet_run_layer_path "$run_layer" ||
        fail "a layer file was not recognised as one: $run_layer"
    done
    for run_record in journal/vireo/2026-08-07.yaml applied/vireo.yaml \
      alerts/vireo/x.yaml definitions/nested/file.yaml README.md .roundhouse-sync-store; do
      ! fleet_run_layer_path "$run_record" ||
        fail "a replicated record was treated as a layer: $run_record"
    done
    # B-2: ssh_run must not consume the host-list stdin that feeds readiness.
    # A real SSH transport is replaced with a fixture function here; each of
    # three hosts still exercises both readiness probes, so one drained
    # heredoc would leave a visible missing host and call count.
    (
    run_readiness_config="$run_root/readiness-config.json"
    run_readiness_calls="$run_root/readiness-ssh-calls"
    cat >"$run_readiness_config" <<'JSON'
{
  "version": 1,
  "machines": {
    "readiness-a": {"platform":"linux","transport":"ssh","ssh_alias":"readiness-a","expected_hostname":"readiness-a","expected_user":"fixture","groups":[],"package_managers":[]},
    "readiness-b": {"platform":"linux","transport":"ssh","ssh_alias":"readiness-b","expected_hostname":"readiness-b","expected_user":"fixture","groups":[],"package_managers":[]},
    "readiness-c": {"platform":"linux","transport":"ssh","ssh_alias":"readiness-c","expected_hostname":"readiness-c","expected_user":"fixture","groups":[],"package_managers":[]}
  }
}
JSON
    chmod 600 "$run_readiness_config"
    : >"$run_readiness_calls"
    ssh_run() {
      cat >/dev/null
      printf '%s\n' "$1" >>"$run_readiness_calls"
      case $* in
        *'roundhouse fleet-doctor'*) printf 'ok remote-posture\n' ;;
        *) printf 'missing:\nhostname:%s\nuser:fixture\n' "$1" ;;
      esac
    }
    run_readiness_status=0
    ROUNDHOUSE_CONFIG="$run_readiness_config" \
      fleet_readiness_command readiness-a readiness-b readiness-c \
      >"$run_root/readiness-output" 2>&1 || run_readiness_status=$?
    [ "$run_readiness_status" -eq 0 ] ||
      fail "three-host readiness fixture exited $run_readiness_status: $(cat "$run_root/readiness-output")"
    for run_readiness_host in readiness-a readiness-b readiness-c; do
      grep -Fqx "$run_readiness_host" "$run_readiness_calls" ||
        fail "readiness never called ssh_run for $run_readiness_host"
      [ "$(grep -Fc "$run_readiness_host" "$run_readiness_calls")" -eq 2 ] ||
        fail "readiness did not complete both SSH probes for $run_readiness_host"
    done
    )

    # §4's reader's choice: a scalar IS the state, a map carries it.
    [ "$(fleet_run_state_of '"enabled"')" = enabled ] ||
      fail "a scalar state did not read as itself"
    [ "$(fleet_run_state_of '{"state":"disabled","marketplace":"x"}')" = disabled ] ||
      fail "the map form's state key did not win"
    # `state: false` is a STATE, not an absence: jq's `//` treats false and null
    # alike, so this used to read as `enabled` and turn a stop into a start.
    [ "$(fleet_run_state_of '{"state":false}')" = false ] ||
      fail "a false state read as something else; jq's // swallowed it"
    [ "$(fleet_run_state_of '{"marketplace":"x"}')" = enabled ] ||
      fail "a map with no state key did not default to enabled"

    # --- the apply layer, per category ---
    cat >"$run_root/definitions.yaml" <<'YAML'
packages:
  jj:
    homebrew: jj
    apt: unavailable
YAML
    run_defs=$(yq -o=json -I=0 '.' "$run_root/definitions.yaml")

    # U23: a marketplace's resolved source SHA is the installed-byte identity.
    # Same version + same SHA is a no-op; same version + new SHA and a version
    # advance both reinstall through the native Claude manager.
    run_plugin_defs='{"plugins":{"example":{"marketplace":"test-market"}}}'
    run_sha_old=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    run_sha_new=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    run_plugin_catalog="$run_root/plugin-catalog.json"
    run_plugin_installed="$HOME/.claude/plugins/installed_plugins.json"
    run_plugin_install_marker="$run_root/plugin-installs"
    mkdir -p "$(dirname "$run_plugin_installed")"

    # B-1 characterization first: on Claude 2.1.229 the installed plugin is
    # absent from --available, so the existing identity gate has no SHA and
    # must hold. The next assertion supplies the marketplace manifest and
    # inverts that same failure without changing the installed record.
    run_plugin_missing_catalog="$run_root/plugin-catalog-missing.json"
    run_plugin_marketplace="$run_root/test-marketplace"
    run_plugin_marketplace_file="$run_root/plugin-marketplaces.json"
    printf '%s\n' '{"available":[]}' >"$run_plugin_missing_catalog"
    printf '%s\n' "{\"version\":2,\"plugins\":{\"example@test-market\":[{\"scope\":\"user\",\"version\":\"1.2.3\",\"gitCommitSha\":\"$run_sha_old\"}]}}" >"$run_plugin_installed"
    run_identity_status=0
    CLAUDE_PLUGIN_CATALOG_FILE="$run_plugin_missing_catalog" \
      CLAUDE_CONFIG_DIR="$HOME/.claude" \
      fleet_run_plugin_identity_matches \
      "$run_plugin_defs" example '{"state":"enabled","marketplace":"test-market"}' ||
      run_identity_status=$?
    [ "$run_identity_status" -eq 75 ] ||
      fail "an installed plugin missing from --available did not hold (got $run_identity_status)"
    mkdir -p "$run_plugin_marketplace/.claude-plugin"
    cat >"$run_plugin_marketplace/.claude-plugin/marketplace.json" <<JSON
{"name":"test-market","plugins":[{"name":"example","version":"1.2.3","source":{"source":"git","url":"https://example.invalid/roundhouse.git","sha":"$run_sha_old"}}]}
JSON
    printf '%s\n' "[{\"name\":\"test-market\",\"installLocation\":\"$run_plugin_marketplace\"}]" \
      >"$run_plugin_marketplace_file"
    CLAUDE_PLUGIN_CATALOG_FILE="$run_plugin_missing_catalog" \
      CLAUDE_PLUGIN_MARKETPLACE_FILE="$run_plugin_marketplace_file" \
      CLAUDE_CONFIG_DIR="$HOME/.claude" fleet_run_plugin_identity_matches \
      "$run_plugin_defs" example '{"state":"enabled","marketplace":"test-market"}' ||
      fail "the marketplace manifest did not invert the installed-plugin hold"
    CLAUDE_PLUGIN_LIST_FAIL=1 CLAUDE_PLUGIN_MARKETPLACE_FILE="$run_plugin_marketplace_file" \
      CLAUDE_CONFIG_DIR="$HOME/.claude" fleet_run_plugin_identity_matches \
      "$run_plugin_defs" example '{"state":"enabled","marketplace":"test-market"}' ||
      fail "a failed --available query did not fall back to the marketplace manifest"
    : >"$run_plugin_install_marker"
    CLAUDE_PLUGIN_CATALOG_FILE="$run_plugin_missing_catalog" \
      CLAUDE_PLUGIN_MARKETPLACE_FILE="$run_plugin_marketplace_file" \
      CLAUDE_CONFIG_DIR="$HOME/.claude" CLAUDE_INSTALL_MARKER="$run_plugin_install_marker" \
      fleet_run_apply_item "$run_store" vireo "$run_plugin_defs" plugins.example \
        '"enabled"' '' >/dev/null || fail "fallback catalog apply failed"
    [ ! -s "$run_plugin_install_marker" ] ||
      fail "fallback catalog reapplied an already-matching plugin"
    run_marketplace_update_marker="$run_root/marketplace-updates"
    : >"$run_marketplace_update_marker"
    (
      fleet_trust_prune_expired() { :; }
      fleet_trust_age_evidence() { :; }
      fleet_enroll_process_joins() { :; }
      fleet_seed_command() { :; }
      fleet_run_proposals() { :; }
      fleet_package_pinned() { return 0; }
      fleet_doctor_command() { :; }
      CLAUDE_MARKETPLACE_UPDATE_MARKER="$run_marketplace_update_marker" \
        fleet_run_full_pass "$run_store" vireo \
        '{"plugins":{"example":"enabled"}}' "$run_plugin_defs" \
        "$run_root/layers" "$run_root/full-tmp" >/dev/null
      grep -Fqx test-market "$run_marketplace_update_marker" ||
        fail "full cadence did not refresh a marketplace supplied by definitions"
    )
    run_unsafe_market=$(fleet_run_plugin_marketplaces \
      '{"plugins":{"example":"enabled"}}' \
      '{"plugins":{"example":{"marketplace":"../hosts"}}}')
    [ -z "$run_unsafe_market" ] ||
      fail "full cadence exposed an unsafe definitions marketplace"
    run_held_market_dir="$run_root/held-market"
    mkdir -p "$run_held_market_dir"
    printf '%s\n' 'definitions.plugins.example held-by-test' \
      >"$run_held_market_dir/sigholds"
    run_held_market=$(fleet_run_plugin_marketplaces \
      '{"plugins":{"example":"enabled"}}' "$run_plugin_defs" \
      "$run_held_market_dir/sigholds" "$run_held_market_dir/verdicts")
    [ -z "$run_held_market" ] ||
      fail "full cadence refreshed a marketplace from a held definition"
    run_runtime_hold_file="$run_root/runtime-sigholds"
    run_runtime_verdict_file="$run_root/runtime-verdicts"
    : >"$run_runtime_hold_file"
    : >"$run_runtime_verdict_file"
    fleet_run_runtime_hold definitions.plugins.example 'apply status 75' \
      "$run_runtime_hold_file"
    run_runtime_market=$(fleet_run_plugin_marketplaces \
      '{"plugins":{"example":"enabled"}}' "$run_plugin_defs" \
      "$run_runtime_hold_file" "$run_runtime_verdict_file")
    [ -z "$run_runtime_market" ] ||
      fail "full cadence refreshed a marketplace after an apply-time hold"
    printf '%s\n' 'held plugins.example digest-from-verdict' \
      >"$run_runtime_verdict_file"
    run_runtime_market=$(fleet_run_plugin_marketplaces \
      '{"plugins":{"example":"enabled"}}' "$run_plugin_defs" '' \
      "$run_runtime_verdict_file")
    [ -z "$run_runtime_market" ] ||
      fail "full cadence ignored a held verdict while refreshing a marketplace"
    run_effective_hold_file="$run_root/effective-sigholds"
    run_effective_verdict_file="$run_root/effective-verdicts"
    printf '%s\n' 'definitions.packages.deleted-a deleted by test' \
      'plugins.example held by test' >"$run_effective_hold_file"
    printf '%s\n' 'converge plugins.example digest-from-verdict' \
      >"$run_effective_verdict_file"
    fleet_run_hold_items_into_verdicts "$run_effective_hold_file" \
      "$run_effective_verdict_file" "$run_root"
    grep -Fqx 'held definitions.packages.deleted-a' \
      "$run_effective_verdict_file" ||
      fail "a held parent-only item did not enter the effective verdicts"
    [ "$(grep -Fc 'plugins.example' "$run_effective_verdict_file")" -eq 1 ] ||
      fail "an existing verdict was duplicated while promoting holds"
    run_definition_hold_file="$run_root/definition-sigholds"
    run_definition_values="$run_root/definition-values"
    run_definition_verdict_file="$run_root/definition-verdicts"
    printf '%s\n' 'definitions.plugins.example refused definition' \
      >"$run_definition_hold_file"
    printf '%s\n' 'plugins.example desired-digest' >"$run_definition_values"
    printf '%s\n' 'converge plugins.example desired-digest' \
      >"$run_definition_verdict_file"
    fleet_run_definition_hold_consumers "$run_definition_hold_file" \
      "$run_definition_values" "$run_root"
    fleet_run_hold_items_into_verdicts "$run_definition_hold_file" \
      "$run_definition_verdict_file" "$run_root"
    grep -Fqx 'held plugins.example' "$run_definition_verdict_file" ||
      fail "a held definition did not hold its desired consumer"
    run_unsafe_store="$run_root/unsafe-upstream-store"
    mkdir -p "$run_unsafe_store"
    ! fleet_upstream_write "$run_unsafe_store" ../hosts vireo failed ||
      fail "the upstream record sink accepted a traversal id"
    [ ! -e "$run_unsafe_store/hosts/vireo.yaml" ] ||
      fail "an unsafe upstream id escaped into the store"
    cat >"$run_plugin_marketplace/.claude-plugin/marketplace.json" <<JSON
{"name":"test-market","plugins":[{"name":"example","version":"1.2.3","source":{"source":"git","url":"https://example.invalid/roundhouse.git"}}]}
JSON
    run_identity_status=0
    CLAUDE_PLUGIN_CATALOG_FILE="$run_plugin_missing_catalog" \
      CLAUDE_PLUGIN_MARKETPLACE_FILE="$run_plugin_marketplace_file" \
      CLAUDE_CONFIG_DIR="$HOME/.claude" fleet_run_plugin_identity_matches \
      "$run_plugin_defs" example '{"state":"enabled","marketplace":"test-market"}' ||
      run_identity_status=$?
    [ "$run_identity_status" -eq 75 ] ||
      fail "a marketplace entry without a SHA did not hold"
    cat >"$run_plugin_marketplace/.claude-plugin/marketplace.json" <<JSON
{"name":"test-market","plugins":[{"name":"example","version":"1.2.3","source":{"source":"git","url":"https://example.invalid/roundhouse.git","sha":"$run_sha_old"}}]}
JSON

    printf '%s\n' "{\"available\":[{\"pluginId\":\"example@test-market\",\"version\":\"1.2.3\",\"source\":{\"sha\":\"$run_sha_old\"}}]}" >"$run_plugin_catalog"
    printf '%s\n' "{\"version\":2,\"plugins\":{\"example@test-market\":[{\"scope\":\"user\",\"version\":\"1.2.3\",\"gitCommitSha\":\"$run_sha_old\"}]}}" >"$run_plugin_installed"
    CLAUDE_PLUGIN_CATALOG_FILE="$run_plugin_catalog" \
      CLAUDE_CONFIG_DIR="$HOME/.claude" fleet_run_plugin_identity_matches \
      "$run_plugin_defs" example '{"state":"enabled","marketplace":"test-market"}' ||
      fail "same-version/same-SHA ownership identity did not match"
    CLAUDE_PLUGIN_CATALOG_FILE="$run_plugin_catalog" \
      CLAUDE_CONFIG_DIR="$HOME/.claude" CLAUDE_INSTALL_MARKER="$run_plugin_install_marker" \
      fleet_run_apply_item "$run_store" vireo "$run_plugin_defs" plugins.example \
        '"enabled"' '' >/dev/null || fail "same-SHA plugin apply failed"
    [ ! -s "$run_plugin_install_marker" ] ||
      fail "same-version/same-SHA plugin was reinstalled"
    printf '%s\n' "{\"available\":[{\"pluginId\":\"example@test-market\",\"version\":\"1.2.3\",\"source\":{\"sha\":\"$run_sha_new\"}}]}" >"$run_plugin_catalog"
    run_identity_status=0
    CLAUDE_PLUGIN_CATALOG_FILE="$run_plugin_catalog" \
      CLAUDE_CONFIG_DIR="$HOME/.claude" fleet_run_plugin_identity_matches \
      "$run_plugin_defs" example '{"state":"enabled","marketplace":"test-market"}' ||
      run_identity_status=$?
    [ "$run_identity_status" -eq 1 ] ||
      fail "same-version/new-SHA ownership identity did not require reinstall"
    CLAUDE_PLUGIN_CATALOG_FILE="$run_plugin_catalog" \
      CLAUDE_CONFIG_DIR="$HOME/.claude" CLAUDE_INSTALL_MARKER="$run_plugin_install_marker" \
      fleet_run_apply_item "$run_store" vireo "$run_plugin_defs" plugins.example \
        '"enabled"' '' >/dev/null || fail "same-version/new-SHA plugin apply failed"
    grep -qx 'example@test-market' "$run_plugin_install_marker" ||
      fail "same-version/new-SHA plugin was not reinstalled"
    : >"$run_plugin_install_marker"
    printf '%s\n' "{\"available\":[{\"pluginId\":\"example@test-market\",\"version\":\"1.3.0\",\"source\":{\"sha\":\"$run_sha_new\"}}]}" >"$run_plugin_catalog"
    printf '%s\n' "{\"version\":2,\"plugins\":{\"example@test-market\":[{\"scope\":\"user\",\"version\":\"1.2.3\",\"gitCommitSha\":\"$run_sha_new\"}]}}" >"$run_plugin_installed"
    CLAUDE_PLUGIN_CATALOG_FILE="$run_plugin_catalog" \
      CLAUDE_CONFIG_DIR="$HOME/.claude" CLAUDE_INSTALL_MARKER="$run_plugin_install_marker" \
      fleet_run_apply_item "$run_store" vireo "$run_plugin_defs" plugins.example \
        '"enabled"' '' >/dev/null || fail "version-advance plugin apply failed"
    grep -qx 'example@test-market' "$run_plugin_install_marker" ||
      fail "version-advance plugin was not reinstalled"

    # U23 regression: a plugin never installed before has no record at all
    # (no installed_plugins.json, or no entry for its id) — that is an empty
    # identity requiring install, not a malformed-metadata hold.
    : >"$run_plugin_install_marker"
    rm -f "$run_plugin_installed"
    printf '%s\n' "{\"available\":[{\"pluginId\":\"example@test-market\",\"version\":\"1.3.0\",\"source\":{\"sha\":\"$run_sha_new\"}}]}" >"$run_plugin_catalog"
    CLAUDE_PLUGIN_CATALOG_FILE="$run_plugin_catalog" \
      CLAUDE_CONFIG_DIR="$HOME/.claude" CLAUDE_INSTALL_MARKER="$run_plugin_install_marker" \
      fleet_run_apply_item "$run_store" vireo "$run_plugin_defs" plugins.example \
        '"enabled"' '' >/dev/null || fail "never-installed plugin apply failed"
    grep -qx 'example@test-market' "$run_plugin_install_marker" ||
      fail "never-installed plugin (no installed_plugins.json) was not installed"
    : >"$run_plugin_install_marker"
    printf '%s\n' '{"version":2,"plugins":{}}' >"$run_plugin_installed"
    CLAUDE_PLUGIN_CATALOG_FILE="$run_plugin_catalog" \
      CLAUDE_CONFIG_DIR="$HOME/.claude" CLAUDE_INSTALL_MARKER="$run_plugin_install_marker" \
      fleet_run_apply_item "$run_store" vireo "$run_plugin_defs" plugins.example \
        '"enabled"' '' >/dev/null || fail "no-record plugin apply failed"
    grep -qx 'example@test-market' "$run_plugin_install_marker" ||
      fail "never-installed plugin (no entry in installed_plugins.json) was not installed"

    # §5.1.3: a STANDALONE hook is arbitrary code from outside the plugin trust
    # flow. It folds, resolves, reviews and journals — and the apply path
    # refuses it. The gate itself is exercised in tests/75-guards.sh; what is
    # asserted here is that the apply path consumes it as a HARD REFUSAL.
    run_status=0
    fleet_run_apply_item "$run_store" vireo "$run_defs" hooks.commit-guard \
      '"enabled"' '' >/dev/null 2>&1 || run_status=$?
    [ "$run_status" -eq 75 ] ||
      fail "an ungated standalone hook reached the apply path (got $run_status)"

    # A host with only apt cannot get jj, and §5.1's rule is "never a guess,
    # never a silent skip": the item HOLDS.
    run_status=0
    fleet_run_apply_item "$run_store" vireo "$run_defs" packages.jj \
      '"enabled"' apt >/dev/null 2>&1 || run_status=$?
    [ "$run_status" -eq 75 ] ||
      fail "an explicitly unavailable package did not hold (got $run_status)"

    # §6: on a managed config key the run REPORTS the drift and changes
    # nothing. A twice-daily job that silently reverts what someone typed four
    # hours ago is the exact surprise this system exists not to deliver. The
    # report reads each managed key's CURRENT on-disk value and prints it.
    mkdir -p "$HOME/.claude"
    printf '{"model":"opus","env":{}}\n' >"$HOME/.claude/settings.json"
    run_drift_out=$(fleet_run_apply_item "$run_store" vireo "$run_defs" \
      'config_files.~/.claude/settings.json' '{"keys":{"model":"managed"}}' '') ||
      fail "config_files did not converge as a report-only category"
    case $run_drift_out in
      *'config_files.~/.claude/settings.json model  on-disk="opus"'*) ;;
      *) fail "the managed-key drift report did not show the on-disk value: $run_drift_out" ;;
    esac
    # A managed key absent from the file is reported (null), never installed.
    run_drift_out=$(fleet_run_apply_item "$run_store" vireo "$run_defs" \
      'config_files.~/.claude/settings.json' '{"keys":{"telemetry.off":"managed"}}' '')
    case $run_drift_out in
      *'telemetry.off  on-disk=null'*) ;;
      *) fail "an absent managed key was not reported by the drift pass: $run_drift_out" ;;
    esac
    # An UNMANAGED key is not read or reported (§5), and the file is unchanged.
    run_drift_out=$(fleet_run_apply_item "$run_store" vireo "$run_defs" \
      'config_files.~/.claude/settings.json' '{"keys":{"model":"unmanaged"}}' '')
    case $run_drift_out in
      *'on-disk='*) fail "an unmanaged key was compared or reported: $run_drift_out" ;;
    esac
    [ "$(jq -r '.model' "$HOME/.claude/settings.json")" = opus ] ||
      fail "the drift report modified the config file — it must change nothing"

    # Declared boundary B-3: no state verb and no observed state either. 70 is
    # SATISFIED — nothing to do, here or on any host — and the canary gate
    # reads it as evidence, so the split from 75 is not cosmetic.
    for run_gap in agents.triage-bot mcp_servers.linear projects.roundhouse; do
      run_status=0
      fleet_run_apply_item "$run_store" vireo "$run_defs" "$run_gap" \
        '"enabled"' '' >/dev/null 2>&1 || run_status=$?
      [ "$run_status" -eq 70 ] ||
        fail "$run_gap claimed an apply path it does not have (got $run_status)"
    done
    # An UNKNOWN category is HELD, never satisfied. §7.7 holds the whole store
    # on a top-level key that is neither a category nor a host fact, so the run
    # never reaches the apply layer for one — but `fleet-apply ITEM` is invoked
    # directly and does. 70 here would journal `satisfied` for state this build
    # cannot interpret, which is positive canary evidence peers act on.
    for run_unknown in widgets.thing definitions_typo.x 'Plugins.Railyard'; do
      run_status=0
      fleet_run_apply_item "$run_store" vireo "$run_defs" "$run_unknown" \
        '"enabled"' '' >/dev/null 2>&1 || run_status=$?
      [ "$run_status" -eq 75 ] ||
        fail "unknown category $run_unknown reached satisfied evidence (got $run_status)"
    done
    # An UNRECOGNISED STATE is HELD, for every category. A typo (`enable`) or a
    # wrong type (`state: false`) used to fall into whatever each arm does with
    # "not enabled": packages reported SATISFIED — positive canary evidence that
    # malformed desired state had converged fleet-wide — and plugins silently
    # DISABLED the plugin.
    for run_badstate in '"enable"' '"Enabled"' '{"state":false}' '{"state":"on"}' \
      '"present"'; do
      for run_baditem in packages.jj plugins.railyard skills.tdd agents.triage-bot; do
        run_status=0
        fleet_run_apply_item "$run_store" vireo "$run_defs" "$run_baditem" \
          "$run_badstate" homebrew >/dev/null 2>&1 || run_status=$?
        [ "$run_status" -eq 75 ] ||
          fail "$run_baditem at state $run_badstate was not held (got $run_status)"
      done
    done
    # …and a value that carries NO state at all still reads `enabled` (§4), so
    # the guard does not catch config_files or definitions maps.
    fleet_run_apply_item "$run_store" vireo "$run_defs" \
      definitions.packages.jj '{"homebrew":"jj"}' '' ||
      fail "the unknown-state guard caught a definitions map that states no state"
    # POLICY AND DEFINITIONS ARE NOT STATES and must dispatch BEFORE the guard.
    # `policy.cadence_hours: 12` is a scalar that is neither enabled nor
    # disabled, so guarding it first would hold every policy item on every host
    # forever and downstream hosts could never get the canary evidence a policy
    # change needs.
    for run_policy_item in 'policy.cadence_hours 12' \
      'policy.canary_group "canary"' 'policy.canary_wait_hours 0' \
      'definitions.packages.jj "jj"'; do
      fleet_run_apply_item "$run_store" vireo "$run_defs" \
        "${run_policy_item%% *}" "${run_policy_item#* }" '' ||
        fail "a policy/definitions item was held by the state guard: $run_policy_item"
    done
    # A desired state of `disabled` on a package is the same shape: removal is
    # §10.3's separate capped decision driven by applied/, never this path, so
    # there is nothing to do rather than something that was refused — and that
    # holds whether or not this host has a manager that could have PROVIDED the
    # package, which is why the state is asked before the resolver. Asking the
    # resolver first made an unprovidable disabled package journal `held` and
    # block every downstream host on evidence nobody could ever produce.
    for run_pkg_managers in homebrew apt ''; do
      run_status=0
      fleet_run_apply_item "$run_store" vireo "$run_defs" packages.jj \
        '"disabled"' "$run_pkg_managers" >/dev/null 2>&1 || run_status=$?
      [ "$run_status" -eq 70 ] ||
        fail "a disabled package with managers '$run_pkg_managers' did not read as satisfied (got $run_status)"
    done
    # …and the other side of the split: a miss about THIS HOST's capability is
    # HELD, never satisfied. A peer that CAN apply the item must not converge
    # on this host's inability, so those misses have to keep blocking.
    # A standalone skill this host has nowhere to put (no `skill_roots` in the
    # host-local config) is exactly that shape.
    run_status=0
    fleet_run_apply_item "$run_store" vireo "$run_defs" skills.tdd \
      '"enabled"' '' >/dev/null 2>&1 || run_status=$?
    [ "$run_status" -eq 75 ] ||
      fail "a host that cannot place a standalone skill reported it satisfied (got $run_status)"
    # The harness-absent arm is the same rule and cannot be reached
    # behaviourally here — the fixture PATH ships a `claude` stub — so it is
    # asserted on the apply layer's own text, the way tests/75-guards.sh
    # asserts the publish guards.
    cli_function_body fleet_run_apply_item |
      grep -q 'command -v claude >/dev/null 2>&1 || return 75' ||
      fail "a host with no harness no longer HOLDS a plugin item; it would read as satisfied evidence"
    # A plugin-qualified skill rides its plugin and needs nothing of its own.
    fleet_run_apply_item "$run_store" vireo "$run_defs" \
      skills.superpowers/brainstorming '"enabled"' '' ||
      fail "a plugin-delivered skill was not treated as its plugin's business"
    # Policy is read, not installed; a definition is a lookup, not a want.
    fleet_run_apply_item "$run_store" vireo "$run_defs" \
      definitions.packages.jj '{"homebrew":"jj"}' '' ||
      fail "a definitions item was treated as something to install"

    # --- §5's rendered aliases reach ssh only through the include line ---
    printf 'Host personal\n  HostName elsewhere.invalid\n' >"$run_root/prior-config"
    mkdir -p "$HOME/.ssh"
    cp "$run_root/prior-config" "$HOME/.ssh/config"
    fleet_run_ssh_include || fail "the ssh include line was not ensured"
    [ "$(head -1 "$HOME/.ssh/config")" = "Include $HOME/.ssh/config.d/roundhouse" ] ||
      fail "the include is not first, so ssh_config's first-value-wins rule buries it"
    grep -Fq 'Host personal' "$HOME/.ssh/config" ||
      fail "ensuring the include discarded the operator's own aliases (B-2)"
    fleet_run_ssh_include
    fleet_run_ssh_include
    [ "$(grep -c "^Include $HOME/.ssh/config.d/roundhouse\$" "$HOME/.ssh/config")" -eq 1 ] ||
      fail "the include line is not idempotent"

    # --- §7.6 the verdict, host-local and never replicated ---
    fleet_run_verdict_write plugins.railyard 4f1c9a02e8 'unchanged from the group layer'
    case $(fleet_run_verdict_path plugins.railyard) in
      "$run_root"/store.run/verdicts/*) ;;
      *) fail "the verdict did not land in the host-local store.run/" ;;
    esac
    [ ! -e "$run_store/verdicts" ] ||
      fail "a consent-shaped artifact reached the fleet-writable store"
    [ "$(fleet_run_verdict_digest plugins.railyard)" = 4f1c9a02e8 ] ||
      fail "the stored verdict did not round-trip its digest"

    # --- §8.2b's evidence, assembled from records rather than from claims ---
    printf '%s\n' vireo wren corvid >"$run_root/hosts"
    fleet_applied_record "$run_store" wren plugins.ponytail aaa111 \
      2026-08-07T08:00:00Z
    fleet_run_applied_elsewhere "$run_store" vireo plugins.ponytail aaa111 \
      "$run_root/hosts" ||
      fail "a peer's current applied digest did not count as applied-elsewhere"
    # A value the peer has since moved off is not "applied and not since
    # superseded" — the record shape answers that without a journal replay.
    fleet_applied_record "$run_store" wren plugins.ponytail bbb222 \
      2026-08-07T09:00:00Z
    ! fleet_run_applied_elsewhere "$run_store" vireo plugins.ponytail aaa111 \
      "$run_root/hosts" ||
      fail "a superseded value still read as applied elsewhere"
    ! fleet_run_applied_elsewhere "$run_store" wren plugins.ponytail bbb222 \
      "$run_root/hosts" ||
      fail "a host's own applied record counted as a PEER's evidence"

    fleet_journal_append "$run_store" wren \
      "$(jq -cn '{item:"plugins.ponytail",digest:"bbb222",outcome:"applied",
        at:"2026-08-07T09:00:00Z"}')"
    [ "$(fleet_run_journal_at "$run_store" plugins.ponytail bbb222 "$run_root/hosts")" = \
      2026-08-07T09:00:00Z ] ||
      fail "the journal at-time for a value was not read back"
    [ -z "$(fleet_run_journal_at "$run_store" plugins.ponytail zzz "$run_root/hosts")" ] ||
      fail "an unrecorded digest produced a journal time out of nowhere"

    # The evidence document feeds the ladder unchanged: the split between
    # `grounded` and `asserted` is the safety property, and only rule 2 reads
    # the self-asserted half.
    run_mine='{"grounded":{"value":"v2-vireo","revert_replaced":null,
      "revert_set_to":null,"applied_elsewhere":true,"journal_at":null},
      "asserted":{"session":"scheduled/agent"}}'
    run_theirs='{"grounded":{"value":"v2-wren","revert_replaced":null,
      "revert_set_to":null,"applied_elsewhere":false,"journal_at":null},
      "asserted":{"session":"scheduled/agent"}}'
    run_decision=$(fleet_run_evidence plugins.ponytail 1500 "$run_mine" "$run_theirs" |
      fleet_resolve_decide)
    [ "$(printf '%s\n' "$run_decision" | jq -r '.verdict + " " + (.rule | tostring)')" = \
      'mine 4' ] ||
      fail "the assembled evidence did not reach rule 4: $run_decision"
    # A missing session trailer reads as a human and escalates, which is the
    # conservative default the whole ladder is ordered around.
    run_decision=$(fleet_run_evidence plugins.ponytail 1500 \
      "$(printf '%s\n' "$run_mine" | jq -c '.asserted = {}')" "$run_theirs" |
      fleet_resolve_decide)
    [ "$(printf '%s\n' "$run_decision" | jq -r '.verdict')" = escalate ] ||
      fail "an absent session trailer did not escalate: $run_decision"

    # --- §10.8's revert-signature predicate, wired to this host's own journal ---
    fleet_journal_append "$run_store" vireo \
      "$(jq -cn '{item:"plugins.ponytail",digest:"aaa111",outcome:"applied",
        at:"2026-08-06T09:00:00Z"}')"
    fleet_journal_append "$run_store" vireo \
      "$(jq -cn '{item:"plugins.ponytail",digest:"bbb222",outcome:"applied",
        at:"2026-08-07T09:00:00Z"}')"
    fleet_run_is_revert "$run_store" vireo plugins.ponytail aaa111 ||
      fail "applied-then-withdrawn-now-back did not read as a revert"
    # The mirror assertions: a promotion and a re-signing are the CURRENTLY
    # applied digest and must stay silent, or §7.2's "triggers no review
    # anywhere" stops being true.
    ! fleet_run_is_revert "$run_store" vireo plugins.ponytail bbb222 ||
      fail "the currently applied digest read as a revert (a promotion would re-review)"

    # --- §10.1 canary membership is a grep across the host files ---
    cat >"$run_root/layers/hosts/vireo.yaml" <<'YAML'
platform: macos
groups: [development, canary]
YAML
    cat >"$run_root/layers/hosts/wren.yaml" <<'YAML'
platform: macos
groups: [development]
YAML
    printf '%s\n' vireo wren >"$run_root/canary-hosts"
    [ "$(fleet_run_canary_hosts "$run_root/layers" canary "$run_root/canary-hosts")" = vireo ] ||
      fail "canary membership did not come from the host files' own groups list"

    # --- provenance is FILE, never file:line ---
    mkdir -p "$run_root/layers/groups"
    cat >"$run_root/layers/fleet.yaml" <<'YAML'
plugins:
  ponytail: enabled
YAML
    cat >"$run_root/layers/groups/development.yaml" <<'YAML'
# a comment, which is why yq's line operator is not the answer
plugins:
  ponytail: v1.6.0
YAML
    [ "$(fleet_run_item_layer "$run_root/layers" vireo plugins.ponytail)" = \
      groups/development.yaml ] ||
      fail "the winning layer for an item was not the narrowest one that speaks"
    ! fleet_run_item_layer "$run_root/layers" vireo plugins.nothing 2>/dev/null ||
      fail "an item no layer carries reported a winning file"

    # --- §10.2 seeding: the working copy, and nothing else ---
    # A TEST hook substitutes the inventory snapshot: a fixture that shells out
    # to the real collector passes for the wrong reason on the next runner
    # image, and this hook decides what gets DESCRIBED, never what is trusted.
    cat >"$run_root/snapshot.jsonl" <<'JSONL'
{"kind":"plugin","status":"present","data":{"name":"ponytail","marketplace":"novotnyllc","enabled":true}}
{"kind":"plugin","status":"present","data":{"name":"legal","marketplace":"novotnyllc","enabled":false}}
{"kind":"skill","status":"present","data":{"name":"grilling"}}
{"kind":"package","status":"present","data":{"name":"jq"}}
{"kind":"plugin","status":"absent","data":{"name":"never-installed","marketplace":"x","enabled":true}}
JSONL
    run_seed_host=$(fleet_host_name)
    cat >"$run_store/hosts/$run_seed_host.yaml" <<'YAML'
platform: macos
groups: [development]
plugins:
  hand-authored: enabled
YAML
    run_seed_out=$(ROUNDHOUSE_SELFTEST=1 \
      ROUNDHOUSE_SEED_SNAPSHOT="$run_root/snapshot.jsonl" \
      fleet_seed_command 2>&1) ||
      fail "fleet-seed failed on a fixture snapshot: $run_seed_out"
    case $run_seed_out in
      *'working copy only'*) ;;
      *) fail "fleet-seed did not say it stopped at the working copy: $run_seed_out" ;;
    esac
    run_seeded="$run_store/hosts/$run_seed_host.yaml"
    grep -Fq 'ponytail:' "$run_seeded" ||
      fail "seeding did not describe an installed plugin"
    yq -e '.plugins.legal.state == "disabled"' "$run_seeded" >/dev/null ||
      fail "seeding lost a plugin's disabled state"
    ! grep -Fq 'never-installed' "$run_seeded" ||
      fail "seeding described something the snapshot reports absent"
    # Re-seeding UPSERTS and never removes: a hand-authored entry survives.
    grep -Fq 'hand-authored:' "$run_seeded" ||
      fail "seeding removed a hand-authored entry (re-seed must upsert)"
    # The first convergence after seeding is a no-op BY CONSTRUCTION, which is
    # the safety property worth paying a verbose host file for.
    [ -f "$(fleet_applied_path "$run_store" "$run_seed_host")" ] ||
      fail "seeding wrote no applied/<host>.yaml, so the first run would adopt everything"
    # It stops at the working copy: no describe, no bookmark, no push. There is
    # no repository here at all, and seeding must not need one.
    [ ! -e "$run_store/.jj" ] ||
      fail "fleet-seed created a repository"

    # --- machine truth is SEEDED, not hand-authored (G4) ---
    # `platform` and `groups` are host FACTS the fold reads to pick the `os/`
    # and `groups/` layers. Seeding captured the three observed surfaces and
    # not these, so every enrolled host needed a hand-written hosts/<name>.yaml
    # before its own layers resolved at all. config.json already states both,
    # validated, so there is nothing to infer.
    # `transport: local` because that is how fleet_host_name resolves this
    # machine's own name out of config.json — the same machine the seed writes.
    cat >"$run_root/seed-config.json" <<JSONC
{"version":1,"machines":{"$run_seed_host":{"platform":"linux","transport":"local",
  "groups":["development","canary"],"package_managers":["apt"]}}}
JSONC
    rm -f "$run_seeded"
    ROUNDHOUSE_SELFTEST=1 ROUNDHOUSE_CONFIG="$run_root/seed-config.json" \
      ROUNDHOUSE_SEED_SNAPSHOT="$run_root/snapshot.jsonl" \
      fleet_seed_command >/dev/null 2>&1 ||
      fail "fleet-seed failed with machine facts to seed"
    yq -e '.platform == "linux"' "$run_seeded" >/dev/null ||
      fail "seeding did not take platform from config.json — machine-truth still needs a hand-authored host file"
    [ "$(yq -r '(.groups // []) | join(",")' "$run_seeded")" = development,canary ] ||
      fail "seeding did not take groups from config.json"
    yq -e '.plugins.ponytail != null' "$run_seeded" >/dev/null ||
      fail "seeding the facts cost the observed surfaces"
    # A fact already in the host file WINS: someone wrote it deliberately and
    # seeding is not the place to relitigate it.
    fleet_record_write "$run_seeded" \
      "$(fleet_record_read "$run_seeded" '{}' | jq -c '.platform = "macos"')"
    ROUNDHOUSE_SELFTEST=1 ROUNDHOUSE_CONFIG="$run_root/seed-config.json" \
      ROUNDHOUSE_SEED_SNAPSHOT="$run_root/snapshot.jsonl" \
      fleet_seed_command >/dev/null 2>&1 ||
      fail "re-seeding failed over a hand-authored fact"
    yq -e '.platform == "macos"' "$run_seeded" >/dev/null ||
      fail "seeding overwrote a hand-authored platform with the config's"
    # An EMPTY groups list is a fact, not an absence. The `machine-truth` doctor
    # row compares `.groups // null` on both sides and jq's `//` passes `[]`
    # through, so omitting the field reads as `null` against the config's `[]`
    # and the row fires forever on a correctly configured ungrouped machine.
    cat >"$run_root/seed-nogroups.json" <<JSONC
{"version":1,"machines":{"$run_seed_host":{"platform":"linux","transport":"local",
  "groups":[],"package_managers":[]}}}
JSONC
    rm -f "$run_seeded"
    ROUNDHOUSE_SELFTEST=1 ROUNDHOUSE_CONFIG="$run_root/seed-nogroups.json" \
      ROUNDHOUSE_SEED_SNAPSHOT="$run_root/snapshot.jsonl" \
      fleet_seed_command >/dev/null 2>&1 ||
      fail "fleet-seed refused a machine with no groups to seed"
    # `yq -e '.groups == []'` is NOT usable here: this yq compares sequences by
    # identity, so it reports false for two equal empty lists. Assert the tag
    # and the length, which is what the claim actually is.
    [ "$(yq -r '.groups | tag' "$run_seeded")" = '!!seq' ] &&
      [ "$(yq -r '.groups | length' "$run_seeded")" -eq 0 ] ||
      fail "an empty groups list was dropped instead of seeded; machine-truth would fire forever"
    yq -e '.plugins.ponytail != null' "$run_seeded" >/dev/null ||
      fail "seeding the empty groups list cost the observed surfaces"
    # …and a config that states NO opinion has none invented for it. (The
    # machine stays listed with `transport: local`, because that entry is also
    # how fleet_host_name resolves this machine's own name — drop it and the
    # seed writes a different host file and the assertion below reads a file
    # nothing wrote.)
    cat >"$run_root/seed-silent.json" <<JSONC
{"version":1,"machines":{"$run_seed_host":{"transport":"local"}}}
JSONC
    rm -f "$run_seeded"
    ROUNDHOUSE_SELFTEST=1 ROUNDHOUSE_CONFIG="$run_root/seed-silent.json" \
      ROUNDHOUSE_SEED_SNAPSHOT="$run_root/snapshot.jsonl" \
      fleet_seed_command >/dev/null 2>&1 ||
      fail "fleet-seed refused a machine whose config states no facts"
    [ -f "$run_seeded" ] ||
      fail "the seed wrote a different host file than the fixture expects"
    yq -e '.platform == null and .groups == null and .plugins.ponytail != null' \
      "$run_seeded" >/dev/null ||
      fail "an unlisted machine had facts invented for it"
    # An ABSENT field and an empty list are different answers, and the doctor
    # row reads them differently — so the two cases above must not collapse.
    [ "$(yq -r '.groups | tag' "$run_seeded")" = '!!null' ] ||
      fail "an unlisted machine seeded a groups value rather than leaving it absent"

    # --- §6.1(b) the push-nudge: outbound only, bounded, and deletable ---
    mkdir -p "$run_root/bin"
    cat >"$run_root/bin/ssh" <<'STUB'
#!/bin/sh
# Records the nudge and refuses for one named peer, standing in for a host
# that is asleep, travelling, or on a network with no route.
printf '%s\n' "$*" >>"${ROUNDHOUSE_NUDGE_LOG:?}"
case $* in
  *rh-wren*) exit 255 ;;
esac
exit 0
STUB
    chmod +x "$run_root/bin/ssh"
    ROUNDHOUSE_NUDGE_LOG="$run_root/nudge.log"
    export ROUNDHOUSE_NUDGE_LOG
    : >"$ROUNDHOUSE_NUDGE_LOG"
    (
      PATH="$run_root/bin:$PATH"
      export PATH
      fleet_run_nudge "$run_store" vireo "$run_root/layers" 1500
    )
    grep -q 'rh-wren' "$ROUNDHOUSE_NUDGE_LOG" ||
      fail "the nudge never reached the peer"
    ! grep -q 'rh-vireo' "$ROUNDHOUSE_NUDGE_LOG" ||
      fail "the pushing host nudged itself"
    grep -q 'fleet-run --fast' "$ROUNDHOUSE_NUDGE_LOG" ||
      fail "the nudge carried something other than \"go look\""
    grep -Fqx wren "$(fleet_run_state_dir)/nudge-unreachable" ||
      fail "an unreachable peer was not remembered for the interval"
    # Remembered for ONE interval only, so a peer that comes back is retried.
    : >"$ROUNDHOUSE_NUDGE_LOG"
    (
      PATH="$run_root/bin:$PATH"
      export PATH
      fleet_run_nudge "$run_store" vireo "$run_root/layers" 1500
    )
    ! grep -q 'rh-wren' "$ROUNDHOUSE_NUDGE_LOG" ||
      fail "an unreachable peer was retried inside the same interval"
    : >"$ROUNDHOUSE_NUDGE_LOG"
    (
      PATH="$run_root/bin:$PATH"
      export PATH
      # A zero interval expires the memo immediately, which is the same code
      # path a real interval takes twenty minutes to reach.
      fleet_run_nudge "$run_store" vireo "$run_root/layers" 0
    )
    grep -q 'rh-wren' "$ROUNDHOUSE_NUDGE_LOG" ||
      fail "a peer that came back was never retried"
  )
fi

# --- §7.6/§10.2 the supervised verbs, and the dispatch surface that reaches
# them. Phase 10 landed the mechanics with no way to call them; a verb the CLI
# cannot dispatch is a verb that does not exist, so the table is asserted here
# beside the behaviour.
printf 'verbs: the supervised item-level surface\n'
(
  set -eu
  for verb_name in fleet-review fleet-apply fleet-accept fleet-hold \
    fleet-pending fleet-journal fleet-finding fleet-lock fleet-unlock \
    fleet-set-remote; do
    grep -Fq "  roundhouse $verb_name" "$cli" ||
      fail "$verb_name is missing from the usage heredoc"
    grep -Eq "^  $verb_name\)" "$cli" ||
      fail "$verb_name has no dispatch arm"
  done
  # Arity is checked in dispatch, BEFORE the command function runs, so a
  # malformed invocation can never reach a store at all.
  for verb_bad in 'fleet-review one two' 'fleet-apply' 'fleet-apply a b' \
    'fleet-accept' 'fleet-hold only' 'fleet-pending extra' 'fleet-lock extra' \
    'fleet-set-remote' 'fleet-finding one'; do
    verb_status=0
    # shellcheck disable=SC2086 # the malformed argv under test
    "$cli" $verb_bad >/dev/null 2>&1 || verb_status=$?
    [ "$verb_status" -eq 64 ] ||
      fail "\`roundhouse $verb_bad\` exited $verb_status, not 64"
  done
)

if [ -n "$fleet_fixture_yq" ]; then
  printf 'verbs: review, apply, accept, hold, pending, lock, finding\n'
  (
    set -eu
    PATH=$fleet_fixture_path
    export PATH
    # shellcheck source=/dev/null
    ROUNDHOUSE_LIB_ONLY=1 . "$cli"

    verb_root="$tmp/verbs"
    verb_store="$verb_root/store"
    mkdir -p "$verb_store/hosts" "$verb_store/proposals"
    ROUNDHOUSE_FLEET_STORE=$verb_store
    HOME="$verb_root/home"
    export ROUNDHOUSE_FLEET_STORE HOME
    mkdir -p "$HOME"
    fleet_record_write "$(fleet_identity_path)" '{"name":"vireo"}'
    [ "$(fleet_host_name)" = vireo ] ||
      fail "the fixture host did not resolve through identity.yaml"

    printf '%s\n' 'policy:' '  canary_group: canary' >"$verb_store/fleet.yaml"
    printf '%s\n' 'platform: macos' 'plugins:' '  railyard: enabled' \
      >"$verb_store/hosts/vireo.yaml"
    verb_digest=$(fleet_item_digest "$(fleet_fold "$verb_store" vireo)" \
      plugins.railyard)
    [ -n "$verb_digest" ] || fail "the fixture item resolved to no digest"

    # --- fleet-review: both verdicts through the one writer ---
    fleet_review_command plugins.railyard hold 'the marketplace is down' >/dev/null
    fleet_run_verdict_held plugins.railyard "$verb_digest" ||
      fail "a hold verdict did not bind to the digest under review"
    [ "$(fleet_run_verdict_digest plugins.railyard)" = '' ] ||
      fail "a hold verdict read as a pass"
    # The hold is keyed on the VALUE. A later edit is a value nobody has
    # reviewed, and it must not inherit the refusal.
    ! fleet_run_verdict_held plugins.railyard deadbeef ||
      fail "a hold bound to one digest also held a different one"
    verb_status=0
    fleet_review_command plugins.railyard maybe reason >/dev/null 2>&1 ||
      verb_status=$?
    [ "$verb_status" -eq 64 ] || fail "a third verdict word was accepted"
    verb_status=0
    fleet_review_command plugins.railyard pass '' >/dev/null 2>&1 || verb_status=$?
    [ "$verb_status" -eq 64 ] || fail "a reasonless verdict was accepted"

    # --- fleet-apply: the verdict gate is the point ---
    verb_status=0
    fleet_apply_command plugins.railyard >/dev/null 2>&1 || verb_status=$?
    [ "$verb_status" -eq 65 ] ||
      fail "fleet-apply ran with no passing review (exit $verb_status)"
    fleet_review_command plugins.railyard pass 'reviewed by hand' >/dev/null
    [ "$(fleet_run_verdict_digest plugins.railyard)" = "$verb_digest" ] ||
      fail "the pass verdict did not bind the current digest"
    # A verdict that no longer names the current value fails exactly like an
    # absent one: a stale pass is not a pass.
    fleet_run_verdict_write plugins.railyard stale00000 'yesterday' human pass
    verb_status=0
    fleet_apply_command plugins.railyard >/dev/null 2>&1 || verb_status=$?
    [ "$verb_status" -eq 65 ] || fail "a stale pass verdict authorised an apply"
    fleet_review_command plugins.railyard pass 'reviewed by hand' >/dev/null

    # --- fleet-accept: a promotion moves WHERE a value lives, never what it is
    fleet_record_write "$verb_store/proposals/promote-skills-tdd.yaml" \
      '{"proposes":"move","item":"skills.tdd","value":"enabled",
        "from":["vireo"],"to":"fleet.yaml","by":"vireo",
        "evidence":"identical in every enrolled host file","at":"2026-08-07T00:00:00Z"}'
    fleet_record_write "$verb_store/hosts/vireo.yaml" \
      "$(fleet_record_read "$verb_store/hosts/vireo.yaml" '{}' |
        jq -c '.skills.tdd = "enabled"')"
    verb_before=$(fleet_item_digest "$(fleet_fold "$verb_store" vireo)" skills.tdd)
    fleet_accept_command promote-skills-tdd >/dev/null
    [ ! -f "$verb_store/proposals/promote-skills-tdd.yaml" ] ||
      fail "an accepted proposal was left to be re-offered"
    [ "$(fleet_record_read "$verb_store/fleet.yaml" '{}' |
      jq -r '.skills.tdd')" = enabled ] ||
      fail "the accepted value never reached the target layer"
    [ "$(fleet_record_read "$verb_store/hosts/vireo.yaml" '{}' |
      jq -r '.skills.tdd // "gone"')" = gone ] ||
      fail "the value was left behind in the host file it was promoted out of"
    [ "$(fleet_item_digest "$(fleet_fold "$verb_store" vireo)" skills.tdd)" = \
      "$verb_before" ] ||
      fail "promotion changed the item's digest, so every host would re-review it"
    # Store content reaching a file path: a proposal cannot name a records
    # directory, or anything outside the layer set, and have this verb write it.
    fleet_record_write "$verb_store/proposals/escape.yaml" \
      '{"proposes":"move","item":"skills.x","value":"enabled","from":[],
        "to":"../../../.ssh/authorized_keys","by":"vireo","evidence":"x",
        "at":"2026-08-07T00:00:00Z"}'
    verb_status=0
    fleet_accept_command escape >/dev/null 2>&1 || verb_status=$?
    [ "$verb_status" -eq 65 ] ||
      fail "a proposal naming a non-layer path was accepted (exit $verb_status)"
    [ ! -e "$verb_root/.ssh/authorized_keys" ] ||
      fail "accepting a proposal wrote outside the store"

    # --- fleet-hold and fleet-pending: the fleet-visible half ---
    fleet_hold_command plugins.railyard 'held pending a marketplace fix' >/dev/null
    fleet_pending_command >"$verb_root/pending"
    grep -q 'plugins.railyard' "$verb_root/pending" ||
      fail "the held item never surfaced in fleet-pending"
    [ "$(jq -rs 'length' <"$verb_root/pending")" -ge 1 ] ||
      fail "fleet-pending did not emit JSON lines"
    # §10.4's floor applies to a hold reason like every other replicated field.
    verb_status=0
    fleet_hold_command plugins.railyard \
      'token ghp_0123456789abcdefghij0123456789abcdef' >/dev/null 2>&1 ||
      verb_status=$?
    [ "$verb_status" -eq 65 ] || fail "a hold reason carrying a secret was written"

    # --- fleet-finding: the only mining output that replicates ---
    fleet_finding_command review-noise 'three sessions hit the same stale pin' \
      >/dev/null
    [ "$(find "$verb_store/findings" -name '*-review-noise.yaml' | grep -c .)" -eq 1 ] ||
      fail "the finding did not land under findings/<host>/"
    verb_status=0
    fleet_finding_command leak 'summary' \
      'sk-0123456789abcdefghij0123456789' >/dev/null 2>&1 || verb_status=$?
    [ "$verb_status" -eq 65 ] || fail "a finding quote carrying a secret was written"

    # --- the run-lock: one runner per host, and a second one STOPS ---
    fleet_lock_command >/dev/null
    verb_status=0
    fleet_lock_command >/dev/null 2>&1 || verb_status=$?
    [ "$verb_status" -eq 75 ] ||
      fail "a second run-lock did not exit 75 (exit $verb_status)"
    fleet_unlock_command >/dev/null
    fleet_lock_command >/dev/null ||
      fail "the lock could not be retaken after fleet-unlock"
    fleet_unlock_command >/dev/null
  )
fi
