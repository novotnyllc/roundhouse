# roundhouse self-check — plugin ownership through a signed fixture fleet pass.
# Reuses the fixture manager commands from 07 and the local jj remote from 90.
# shellcheck shell=bash

if [ "$real_jj_ok" = true ]; then
  (
    set -eu
    rjj="$tmp/capture-pass"
    mkdir -p "$rjj/bin" "$rjj/vireo" "$rjj/home"
    ln -s "$real_jj" "$rjj/bin/jj"
    ln -s "$real_yq" "$rjj/bin/yq"
    export PATH="$rjj/bin:$tmp/bin:$PATH"
    export HOME="$rjj/home" XDG_CONFIG_HOME="$rjj/xdg" JJ_CONFIG="$rjj/jj.toml"
    cat >"$JJ_CONFIG" <<'TOML'
[user]
name = "roundhouse selfcheck"
email = "roundhouse-selfcheck@example.invalid"
[ui]
paginate = "never"
editor = "true"
TOML
    rjj_key vireo
    rjj_krl seed.krl
    "$REAL_GIT" init -q --bare -b main "$rjj/remote.git"
    printf 'name: vireo\ndomain: fleet.example.invalid\n' >"$rjj/vireo/identity.yaml"
    store="$rjj/vireo/store"
    export ROUNDHOUSE_FLEET_STORE="$store" ROUNDHOUSE_SELFTEST=1
    export ROUNDHOUSE_FLEET_SIGNING_KEY="$rjj/vireo-key" ROUNDHOUSE_TRUST_ROOT="$rjj/vireo"
    "$cli" fleet-init >/dev/null
    jj -R "$store" git remote add origin "$rjj/remote.git" >/dev/null
    "$cli" fleet-enroll >/dev/null
    ROUNDHOUSE_FLEET_VISIBILITY_PROBE='printf "Permission denied (publickey)\n" >&2; exit 128' \
      "$cli" fleet-verify-remote >/dev/null
    mkdir -p "$store/fleet" "$store/hosts"
    printf 'platform: macos\ngroups: [canary]\n' >"$store/hosts/vireo.yaml"
    cat >"$store/fleet/capture-probe.yaml" <<'YAML'
# Keep this comment when updating the plugin's state.
policy:
  max_changes_per_run: 5
  max_change_fraction: 1
plugins:
  claude-example: {state: enabled, marketplace: test-market}
  ponytail: {state: absent, marketplace: test-market}
YAML
    export CLAUDE_CONFIG_DIR="$HOME/.claude"
    export CLAUDE_PLUGIN_CATALOG_FILE="$rjj/catalog.json"
    export CLAUDE_PLUGIN_ENABLED_FILE="$rjj/enabled.json"
    export CLAUDE_PLUGIN_ACTION_LOG="$rjj/actions"
    export CLAUDE_INSTALL_MARKER="$rjj/installs"
    export CLAUDE_PLUGIN_MARKETPLACE_FILE="$rjj/markets.json"
    mkdir -p "$CLAUDE_CONFIG_DIR/plugins"
    installed="$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json"
    settings="$CLAUDE_CONFIG_DIR/settings.json"
    sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    jq -cn --arg sha "$sha" '{available: [
      {pluginId:"claude-example@test-market",version:"1.0.0",source:{source:"git",sha:$sha}},
      {pluginId:"ponytail@test-market",version:"1.0.0",source:{source:"git",sha:$sha}}]}' \
      >"$CLAUDE_PLUGIN_CATALOG_FILE"
    printf '%s\n' '[{"name":"test-market","source":"url","url":"https://market.example.invalid/catalog.json"}]' \
      >"$CLAUDE_PLUGIN_MARKETPLACE_FILE"
    printf '%s\n' '{"test-market":{"source":{"source":"url","url":"https://market.example.invalid/catalog.json"}}}' \
      >"$CLAUDE_CONFIG_DIR/plugins/known_marketplaces.json"
    jq -cn --arg sha "$sha" '
      {version:2,plugins: {
        "claude-example@test-market":[{scope:"user",version:"1.0.0",gitCommitSha:$sha}],
        "local-extra@test-market":[{scope:"user",version:"1.0.0",gitCommitSha:$sha}]
      }}' >"$installed"
    printf '%s\n' '{"claude-example@test-market":true,"local-extra@test-market":true}' \
      >"$CLAUDE_PLUGIN_ENABLED_FILE"
    printf '{}\n' >"$settings"
    : >"$CLAUDE_PLUGIN_ACTION_LOG"

    capture_pass() {
      "$cli" fleet-run --fast >"$rjj/pass.log" 2>&1 || {
        cat "$rjj/pass.log" >&2
        fail "signed fixture pass failed ($1)"
      }
    }
    capture_remote() {
      "$REAL_GIT" --git-dir="$rjj/remote.git" "$@"
    }
    capture_layer() {
      capture_remote show main:fleet/capture-probe.yaml
    }
    capture_lib() (
      # shellcheck source=/dev/null
      ROUNDHOUSE_LIB_ONLY=1 . "$cli"
      "$@"
    )
    capture_owner_install() {
      jq --arg sha "$sha" '.plugins["ponytail@test-market"] = [{scope:"user",version:"1.0.0",gitCommitSha:$sha}]' \
        "$installed" >"$installed.next" && mv "$installed.next" "$installed"
      jq '.["ponytail@test-market"] = true' "$CLAUDE_PLUGIN_ENABLED_FILE" >"$rjj/enabled.next" &&
        mv "$rjj/enabled.next" "$CLAUDE_PLUGIN_ENABLED_FILE"
    }
    capture_owner_remove() {
      jq 'del(.plugins["ponytail@test-market"])' "$installed" >"$installed.next" &&
        mv "$installed.next" "$installed"
      jq 'del(.["ponytail@test-market"])' "$CLAUDE_PLUGIN_ENABLED_FILE" >"$rjj/enabled.next" &&
        mv "$rjj/enabled.next" "$CLAUDE_PLUGIN_ENABLED_FILE"
    }
    baseline="$rjj/vireo/store.run/agent-baseline.json"
    capture_pass first
    jq -e '
      .["claude:ponytail@test-market"] == {value:"absent"} and
      .["claude:claude-example@test-market"] == {value:"enabled"} and
      .["claude:local-extra@test-market"] == {value:"enabled", ignored:true}
    ' "$baseline" >/dev/null || fail "first pass did not record agreement and ignore its extra"
    [ -z "$(capture_remote log -1 --format=%s main | grep '^user change' || :)" ] ||
      fail "silent first pass published a captured edit"
    [ "$(capture_layer | yq -r '.plugins.ponytail.state')" = absent ] ||
      fail "first pass changed the tombstone"
    grep -rl 'Use roundhouse fleet-take-local ITEM' "$store/alerts/vireo" >"$rjj/ignored-alerts" &&
      [ "$(wc -l <"$rjj/ignored-alerts" | tr -d ' ')" = 1 ] ||
      fail "first pass did not list its local extras in one adoption alert"
    capture_remote grep -q 'Use roundhouse fleet-take-local ITEM' main -- alerts/vireo ||
      fail "the first pass left its extras alert unpublished"
    [ "$(jj -R "$store" log -r @ --no-graph -T 'if(empty,"empty","dirty")')" = empty ] ||
      fail "the first pass left its working copy dirty"

    capture_owner_install
    : >"$CLAUDE_PLUGIN_ACTION_LOG"
    capture_pass owner-install
    [ "$(capture_layer | yq -r '.plugins.ponytail.state')" = enabled ] ||
      fail "the owner install never reached the declaring layer"
    assert_contains "$(capture_layer)" '# Keep this comment'
    if grep -Fqx 'uninstall ponytail@test-market' "$CLAUDE_PLUGIN_ACTION_LOG"; then
      fail "the pass reverted the owner's install before publishing"
    fi
    assert_contains "$(capture_remote log -1 --format=%s main)" 'user change on vireo: claude:ponytail@test-market enabled'
    capture_remote grep -q 'outcome: captured' main -- journal/vireo ||
      fail "the publish did not journal the captured change"
    jq -e '.["claude:ponytail@test-market"].value == "enabled"' "$baseline" >/dev/null ||
      fail "the published install did not advance agreement"

    capture_late_fixture() {
      local phase=$1 scratch="$rjj/late-$1" desired head
      local valid_observed
      fleet_run_env
      head=$(fleet_vcs_head_origin "$store")
      fleet_run_export "$store" "$head" "$scratch/layers"
      desired=$(fleet_run_desired "$scratch/layers" vireo)
      if [ "$phase" = early ]; then
        valid_observed=$(fleet_capture_collect "$scratch/valid")
        fleet_capture_collect() {
          case $1 in */capture-before) return 1 ;; esac
          printf '%s\n' "$valid_observed"
        }
      fi
      fleet_capture_pass_prepare "$store" vireo "$desired" true true "$scratch" "$scratch/layers"
      if [ "$phase" = discard ]; then
        jq -e 'index("claude:discard-probe@test-market") != null' <<<"$fleet_capture_discards" >/dev/null ||
          fail "late discard fixture did not prepare the discard"
      elif [ "$phase" = early ]; then
        [ "$fleet_capture_items" = '[]' ] || fail "unknown initial inventory derived a capture"
      else
        jq -e 'length == 1 and .[0].id == "claude:ponytail@test-market" and .[0].value == "absent"' \
          <<<"$fleet_capture_items" >/dev/null || fail "late observation fixture did not derive a tombstone"
      fi
      case $phase in
        changed) capture_owner_install ;;
        unavailable|discard) fleet_capture_collect() { return 1; } ;;
      esac
      fleet_capture_pass_publish "$store" vireo "$scratch" "$desired" "$scratch/layers" \
        'fixture late observation' - >"$scratch/publish.log" 2>&1 || {
        cat "$scratch/publish.log" >&2
        fail "late observation fixture could not publish ordinary records"
      }
      [ -e "$(fleet_run_state_dir)/retry-owed" ] ||
        fail "a changed or failed observation did not keep the poll floor open"
      [ "$(cat "$(fleet_run_state_dir)/agent-fingerprint")" = "$fleet_capture_before_fingerprint" ] ||
        fail "the pass acknowledged input that it did not process"
    }
    capture_owner_remove
    capture_lib capture_late_fixture changed
    [ "$(capture_layer | yq -r '.plugins.ponytail.state')" = enabled ] ||
      fail "a reinstall during the pass published a stale removal"
    capture_owner_remove
    capture_lib capture_late_fixture unavailable
    [ "$(capture_layer | yq -r '.plugins.ponytail.state')" = enabled ] ||
      fail "a failed late observation published a stale removal"
    capture_lib capture_late_fixture early
    [ "$(capture_layer | yq -r '.plugins.ponytail.state')" = enabled ] ||
      fail "a healthy late scan published a removal never processed by the pass"
    printf 'real-jj: OK (changed or unknown inventory holds stale captures and owes retry)\n'

    : >"$CLAUDE_PLUGIN_ACTION_LOG"
    capture_pass owner-uninstall
    [ "$(capture_layer | yq -r '.plugins.ponytail.state')" = absent ] ||
      fail "the owner uninstall did not reach the declaring layer as a tombstone"
    if grep -Fqx 'install ponytail@test-market' "$CLAUDE_PLUGIN_ACTION_LOG"; then
      fail "the pass reinstalled the plugin the owner removed"
    fi

    jq --arg sha "$sha" '.plugins["discard-probe@test-market"] = [{scope:"user",version:"1.0.0",gitCommitSha:$sha}]' \
      "$installed" >"$installed.next" && mv "$installed.next" "$installed"
    jq '.["discard-probe@test-market"] = true' "$CLAUDE_PLUGIN_ENABLED_FILE" >"$rjj/enabled.next" &&
      mv "$rjj/enabled.next" "$CLAUDE_PLUGIN_ENABLED_FILE"
    "$cli" fleet-discard claude:discard-probe@test-market >/dev/null
    capture_lib capture_late_fixture discard
    jq -e '.["claude:discard-probe@test-market"] == true' "${baseline%/*}/agent-discard.json" >/dev/null &&
      jq -e 'has("claude:discard-probe@test-market") | not' "$baseline" >/dev/null ||
      fail "the pass consumed an unmanaged discard without a durable ignored baseline"
    capture_pass discard-retry
    jq -e '.["claude:discard-probe@test-market"] == {value:"enabled",ignored:true}' "$baseline" >/dev/null &&
      [ ! -e "${baseline%/*}/agent-discard.json" ] ||
      fail "a verified unmanaged discard did not persist before consuming the decision"
    printf 'real-jj: OK (unmanaged discard waits for a durable ignored baseline)\n'

    jq -cn '{id:"disappeared-discard",discarded:true,confirmed:false,items:[
      {id:"claude:disappeared@test-market",item:"plugins.disappeared",harness:"claude",
       name:"disappeared",value:"enabled",decision:"local"}]}' \
      >"${baseline%/*}/agent-pending-confirm.json"
    capture_pass disappeared-discard
    [ ! -e "${baseline%/*}/agent-pending-confirm.json" ] ||
      fail "an authoritatively absent unmanaged member stranded its discarded batch"
    printf 'real-jj: OK (an authoritatively disappeared discard completes its batch)\n'

    # An interrupted Roundhouse mutation can leave an enabled-state change
    # and a marker. A matching later pass clears the marker after reobserving.
    capture_lib fleet_agent_pending_mark claude claude-example@test-market
    marker=$(capture_lib fleet_agent_pending_path claude:claude-example@test-market)
    jq '.["claude-example@test-market"] = false' "$CLAUDE_PLUGIN_ENABLED_FILE" >"$rjj/enabled.next" &&
      mv "$rjj/enabled.next" "$CLAUDE_PLUGIN_ENABLED_FILE"
    printf '{"fixture_touch":true}\n' >"$settings"
    : >"$CLAUDE_PLUGIN_ACTION_LOG"
    capture_pass marked-disable
    grep -Fqx 'enable claude-example@test-market' "$CLAUDE_PLUGIN_ACTION_LOG" ||
      fail "the interrupted apply was not converged back to the fleet"
    [ ! -e "$marker" ] || fail "agreement did not clear the crash marker"
    [ "$(capture_layer | yq -r '.plugins.claude-example.state')" = enabled ] ||
      fail "the pass captured an edit made by Roundhouse"
    printf 'real-jj: OK (silent ownership baseline, user install/uninstall, crash marker)\n'

    # Move the remote after the capture is derived, as if another host
    # published while this pass was applying its local state.
    capture_owner_install
    capture_publish_race() {
      local scratch="$rjj/race" layers desired observed head workcopy peer rc=0
      fleet_run_env
      fleet_vcs_fetch "$store" origin
      head=$(fleet_vcs_head_origin "$store")
      workcopy=$(jj -R "$store" log -r @ --no-graph -T 'commit_id')
      layers="$scratch/layers"
      fleet_run_export "$store" "$head" "$layers"
      desired=$(fleet_run_desired "$layers" vireo)
      observed=$(fleet_capture_collect "$scratch/observed")
      cp "$baseline" "$scratch/baseline"
      fleet_capture_prepare "$store" vireo "$desired" "$observed" true true "$scratch" "$layers"
      jq -e 'length == 1 and .[0].id == "claude:ponytail@test-market" and .[0].value == "enabled"' \
        <<<"$fleet_capture_items" >/dev/null || fail "race setup did not derive the owner install"
      # Save in the replacement/hash window, for both layer and journal bytes.
      local race_path
      for race_path in fleet/capture-probe.yaml "$(fleet_journal_path "$store" vireo "$(fleet_now)")"; do
        (
          local race_txn="$scratch/hash-race" race_target rc=0
          race_target=$race_path
          case $race_target in "$store/"*) ;; *) race_target=$store/$race_target ;; esac
          fleet_capture_file_install() {
            cat "$1" >"$2" || return 1
            [ "$2" != "$race_target" ] || printf '# owner save during replacement\n' >>"$2"
          }
          fleet_capture_stage "$store" "$race_txn"
          fleet_capture_abort "$store" "$race_txn" || rc=$?
          [ "$rc" -ne 0 ] && grep -q '^# owner save during replacement' "$race_target" ||
            fail "capture rollback erased an owner save in the replacement/hash window"
          while IFS= read -r race_file; do
            if [ -f "$race_txn/capture-stage/files/$race_file" ]; then
              cp "$race_txn/capture-stage/files/$race_file" "$store/$race_file"
            else
              rm -f "$store/$race_file"
            fi
          done <"$race_txn/capture-stage/paths"
          rm -rf "$race_txn"
        )
      done
      printf 'real-jj: OK (prepared layer and journal hashes preserve a racing owner save)\n'
      local transaction
      transaction=$(fleet_capture_transaction_path)
      mkdir "$transaction"
      fleet_capture_transaction_basis "$store" >"$transaction/basis"
      cp -R "$store/journal/vireo" "$scratch/original-journal"
      fleet_capture_stage "$store" "$transaction"
      [ "$(yq -r '.plugins.ponytail.state' "$store/fleet/capture-probe.yaml")" = enabled ] ||
        fail "interrupted capture fixture did not write a staged edit"
      : >"$transaction/publishing"
      rc=0
      "$cli" fleet-run --fast >"$scratch/interrupted.log" 2>&1 || rc=$?
      [ "$rc" -eq 75 ] && grep -q 'interrupted plugin capture' "$scratch/interrupted.log" &&
        [ "$(capture_remote rev-parse main)" = "$head" ] ||
        fail "a pass with an uncertain interrupted capture did not stop before publishing"
      grep -rFq 'Plugin capture was interrupted.' "$store/alerts/vireo" ||
        fail "the interrupted capture did not raise a local alert"
      rm "$transaction/publishing"
      cp "$store/fleet/capture-probe.yaml" "$scratch/staged-layer"
      printf '# owner edit after interruption\n' >>"$store/fleet/capture-probe.yaml"
      rc=0
      fleet_capture_transaction_recover "$store" >"$scratch/edited-recovery.log" 2>&1 || rc=$?
      [ "$rc" -eq 75 ] && [ -d "$transaction" ] &&
        grep -q '^# owner edit after interruption' "$store/fleet/capture-probe.yaml" ||
        fail "interrupted staging recovery overwrote a later owner edit"
      cp "$scratch/staged-layer" "$store/fleet/capture-probe.yaml"
      fleet_capture_transaction_recover "$store"
      cmp -s "$store/fleet/capture-probe.yaml" "$layers/fleet/capture-probe.yaml" &&
        diff -qr "$store/journal/vireo" "$scratch/original-journal" >/dev/null &&
        [ ! -e "$transaction" ] ||
        fail "recovery did not restore an interrupted staging transaction"
      fleet_alert_clear "$store" vireo agent-capture-interrupted agent-capture-interrupted
      workcopy=$(jj -R "$store" log -r @ --no-graph -T 'commit_id')
      printf 'real-jj: OK (interrupted staging rolls back and uncertain publication holds)\n'
      (
        fleet_vcs_op_id() {
          command jj -R "$1" op log --no-graph --limit 1 -T 'id ++ "\n"'
          printf '# owner edit after snapshot\n' >>"$1/fleet/capture-probe.yaml"
        }
        local refused=0
        fleet_capture_pass_publish "$store" vireo "$scratch/refused" "$desired" "$layers" \
          'fixture changed layer' - >"$scratch/refused.log" 2>&1 || refused=$?
        [ "$refused" -ne 0 ] && grep -q '^# owner edit after snapshot' "$store/fleet/capture-probe.yaml" ||
          fail "a staging refusal discarded the owner edit that caused it"
      )
      cp "$layers/fleet/capture-probe.yaml" "$store/fleet/capture-probe.yaml"
      peer="$scratch/peer"
      "$REAL_GIT" clone -q "$rjj/remote.git" "$peer"
      printf 'fixture concurrent edit\n' >"$peer/README.md"
      "$REAL_GIT" -C "$peer" add README.md
      "$REAL_GIT" -C "$peer" -c user.name=fixture -c user.email=fixture@example.invalid \
        -c commit.gpgsign=false commit -qm 'concurrent fixture write'
      "$REAL_GIT" -C "$peer" push -q origin main
      local peer_head
      peer_head=$("$REAL_GIT" -C "$peer" rev-parse HEAD)
      fleet_capture_pass_publish "$store" vireo "$scratch" "$desired" "$layers" \
        'fixture stale capture' - >"$scratch/push.log" 2>&1 || rc=$?
      if [ "$rc" -eq 0 ] || ! grep -Eq 'stale info|unexpectedly moved' "$scratch/push.log"; then
        cat "$scratch/push.log" >&2
        fail "the capture did not stop at the actual stale publisher rejection (rc $rc)"
      fi
      [ "$(capture_remote rev-parse main)" = "$peer_head" ] &&
        [ "$(capture_layer | yq -r '.plugins.ponytail.state')" = absent ] ||
        fail "the stale capture rewrote the peer's remote head"
      cmp -s "$store/fleet/capture-probe.yaml" "$layers/fleet/capture-probe.yaml" &&
        cmp -s "$baseline" "$scratch/baseline" ||
        fail "the stale capture left staged bytes or advanced agreement"
      [ "$(fleet_vcs_heads_local "$store")" = "$head" ] &&
        [ "$(jj -R "$store" log -r @ --no-graph -T 'commit_id')" = "$workcopy" ] ||
        fail "the stale capture left its unpublished commit reachable from main or @"

      fleet_vcs_fetch "$store" origin
      [ "$(fleet_vcs_head_origin "$store")" = "$peer_head" ] ||
        fail "the fixture could not fetch the competing commit"
      fleet_run_export "$store" "$peer_head" "$scratch/fetched"
      desired=$(fleet_run_desired "$scratch/fetched" vireo)
      observed=$(fleet_capture_collect "$scratch/observed-next")
      fleet_capture_prepare "$store" vireo "$desired" "$observed" true true "$scratch" "$scratch/fetched"
      jq -e 'length == 1 and .[0].id == "claude:ponytail@test-market" and .[0].value == "enabled"' \
        <<<"$fleet_capture_items" >/dev/null || fail "the owner install was lost after rejecting the stale publish"
      printf 'real-jj: OK (stale capture push leaves the owner edit ready to derive again)\n'

      # Catch up the fixture's local bookmark, then inject a failure only
      # when jj resets the working copy after its real, successful push.
      jj -R "$store" bookmark set main -r "$peer_head" >/dev/null
      jj -R "$store" new "$peer_head" >/dev/null
      jj() {
        if [ "${3:-}" = new ]; then
          printf 'fixture: checkout failed after push\n' >&2
          return 74
        fi
        command jj "$@"
      }
      rc=0
      fleet_capture_pass_publish "$store" vireo "$scratch/checkout-failure" "$desired" "$scratch/fetched" \
        'fixture checkout failure' - >"$scratch/checkout.log" 2>&1 || rc=$?
      if [ "$rc" -ne 74 ] || ! grep -Fq 'fixture: checkout failed after push' "$scratch/checkout.log"; then
        cat "$scratch/checkout.log" >&2
        fail "the fixture did not reach the post-push checkout failure (rc $rc)"
      fi
      [ "$(capture_layer | yq -r '.plugins.ponytail.state')" = enabled ] &&
        [ "$(yq -r '.plugins.ponytail.state' "$store/fleet/capture-probe.yaml")" = enabled ] ||
        fail "the checkout failure rolled back an already published capture"
      [ "$(fleet_vcs_heads_local "$store")" = "$(capture_remote rev-parse main)" ] ||
        fail "the checkout failure reset the local bookmark past the published capture"
      jq -e '.["claude:ponytail@test-market"].value == "enabled"' "$baseline" >/dev/null &&
        [ ! -e "$transaction" ] ||
        fail "the checkout failure left agreement behind an already published capture"
      printf 'real-jj: OK (a checkout failure preserves and rebaselines the published capture)\n'
    }
    capture_lib capture_publish_race
  )
else
  printf 'NOTICE: plugin capture pass fixture requires real jj >= 0.43 and yq\n'
fi
