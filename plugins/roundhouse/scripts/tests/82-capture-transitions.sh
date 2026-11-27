# roundhouse self-check — Claude state markers after partial mutations.
# shellcheck shell=bash

if [ -n "$fleet_fixture_yq" ]; then
  (
    set -eu
    export PATH="$fleet_fixture_path"
    # shellcheck source=/dev/null
    ROUNDHOUSE_LIB_ONLY=1 . "$cli"
    capture="$tmp/capture-transitions"
    export ROUNDHOUSE_FLEET_STORE="$capture/store" CLAUDE_CONFIG_DIR="$capture/claude"
    mkdir -p "$ROUNDHOUSE_FLEET_STORE" "$CLAUDE_CONFIG_DIR"
    marker=$(fleet_agent_pending_path claude:demo@m)

    fleet_run_plugin_market() { printf 'm\n'; }
    fleet_run_marketplace_source_ok() { :; }
    fleet_run_plugin_catalog_proven() {
      printf '%s\n' '{"source":{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}'
    }
    fleet_run_installed_plugin() {
      if [ -e "$capture/state" ]; then
        fleet_run_plugin_catalog_proven | jq -c '{gitCommitSha:.source.sha}'
      else
        printf '{}\n'
      fi
    }
    fleet_run_plugin_enabled() {
      if [ -f "$capture/state" ]; then cat "$capture/state"
      elif [ "${2:-}" = true ]; then printf 'unknown\n'
      else return 75; fi
    }
    fleet_run_claude_running() { return 1; }
    fleet_run_claude_desktop_running() { return 1; }
    bounded_query() { printf '{"configured":[]}\n'; }
    bounded_verb() {
      case $3 in
        uninstall) rm -f "$capture/state" ;;
        install)
          case ${install_behavior:-install} in
            install) printf 'true\n' >"$capture/state" ;;
            disabled) printf 'false\n' >"$capture/state" ;;
            disabled-error) printf 'false\n' >"$capture/state"; return 1 ;;
            noop) : ;;
            fail) return 1 ;;
          esac ;;
        disable) if [ "${disable_behavior:-fail}" = disable ]; then
          printf 'false\n' >"$capture/state"
        else return 1; fi ;;
        *) return 1 ;;
      esac
    }
    transition_apply() {
      local rc=0
      fleet_run_apply_item "$ROUNDHOUSE_FLEET_STORE" mac '{}' plugins.demo "\"$1\"" '{}' ||
        rc=$?
      [ "$rc" = "$2" ] || fail "apply $1 returned $rc, expected $2"
    }
    transition_matches() {
      fleet_agent_pending_matches "$marker" claude:demo@m "$1" "$2"
    }

    # A successful uninstall still owns the absence after a failed or no-op install.
    for install_behavior in fail noop; do
      fleet_run_plugin_refreshed=
      fleet_run_resolved_sha=fixture
      printf 'true\n' >"$capture/state"
      if fleet_run_plugin_reinstall demo@m previous >/dev/null 2>&1; then
        fail "reinstall reported success without installing ($install_behavior)"
      fi
      transition_matches enabled absent || fail "reinstall lost its completed uninstall ($install_behavior)"
      jq -e '.to == "absent" and (has("via") | not)' "$marker" >/dev/null ||
        fail "reinstall recorded a transition it did not reach"
    done

    # An install can retain the disabled state even when its CLI exit is nonzero.
    for install_behavior in disabled disabled-error; do
      fleet_run_plugin_refreshed=
      printf 'true\n' >"$capture/state"
      reinstall_status=0
      fleet_run_plugin_reinstall demo@m previous >/dev/null 2>&1 || reinstall_status=$?
      case $install_behavior in
        disabled) [ "$reinstall_status" = 0 ] || fail "verified disabled reinstall failed" ;;
        disabled-error) [ "$reinstall_status" = 1 ] || fail "failed reinstall lost its exit status" ;;
      esac
      transition_matches enabled disabled || fail "reinstall lost its verified disabled state"
      ! transition_matches enabled absent || fail "reinstall retained an obsolete uninstall marker"
    done
    unset install_behavior

    # Install succeeds, but the failed disable neither erases the install nor owns a disable.
    rm -f "$marker" "$capture/state"
    transition_apply disabled 74
    transition_matches absent enabled || fail "install followed by a failed disable lost its origin"
    ! transition_matches absent disabled || fail "failed disable recorded an unreached state"

    # Retry the disable after an interrupted first pass and then let the third pass converge.
    fleet_capture_mark_claude demo@m absent disabled enabled
    transition_apply disabled 74
    transition_matches absent enabled || fail "failed retry dropped the first install's origin"
    ! transition_matches absent disabled || fail "failed retry still attributes an unreached state"
    fleet_run_plugin_refreshed=
    fleet_run_plugin_reinstall demo@m previous >/dev/null 2>&1 ||
      fail "composed retry could not refresh changed bytes"
    transition_apply disabled 74
    transition_matches absent enabled || fail "reinstall dropped the first install's origin"
    disable_behavior=disable
    transition_apply disabled 0
    transition_matches absent disabled || fail "successful retry dropped the first install's origin"
    ! transition_matches absent enabled || fail "successful retry still attributes the intermediate enable"
    disable_behavior=fail

    # A fresh install that starts disabled owns that state even if an enable no-ops.
    rm -f "$marker" "$capture/state"
    install_behavior=disabled
    fleet_run_approve_plugin_hooks() { :; }
    fleet_run_codex_hooks_scoped() { :; }
    transition_apply enabled 74
    transition_matches absent disabled || fail "no-op enable lost the install's verified disabled state"
    ! transition_matches absent enabled || fail "no-op enable claimed an unreached state"

    # A failed standalone state verb must not hide the owner's next edit.
    for wanted in enabled disabled; do
      rm -f "$marker"
      case $wanted in
        enabled) printf 'false\n' >"$capture/state" ;;
        disabled) printf 'true\n' >"$capture/state" ;;
      esac
      transition_apply "$wanted" 74
      [ ! -e "$marker" ] || fail "unchanged $wanted request left a marker"
    done
  )
fi
