# roundhouse self-check — Claude journal after partial mutations.
# roundhouse-test: parts=14
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
    baseline="$(fleet_run_state_dir)/agent-baseline.json"
    transition_journal="${baseline%/*}/agent-journal/claude.demo@m"

    fleet_run_plugin_market() { printf 'm\n'; }
    fleet_run_marketplace_source_ok() { :; }
    plugin_cache_seal_permissions() { :; }
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
    fleet_run_installed_plugins() {
      if [ -e "$capture/state" ]; then
        printf '%s\n' '{"demo@m":[{"scope":"user"}],"anchor@other":[{"scope":"user"}]}'
      else
        printf '%s\n' '{"anchor@other":[{"scope":"user"}]}'
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
      printf '%s\n' "$3" >>"$capture/actions"
      if [ -f "$transition_journal" ]; then
        jq -c '.intent' "$transition_journal" >>"$capture/intents"
      fi
      case $3 in
        uninstall)
          [ "${uninstall_behavior:-uninstall}" != fail ] || return 1
          rm -f "$capture/state" ;;
        install)
          case ${install_behavior:-install} in
            install) printf 'true\n' >"$capture/state" ;;
            disabled) printf 'false\n' >"$capture/state" ;;
            disabled-error) printf 'false\n' >"$capture/state"; return 1 ;;
            noop) : ;;
            fail) return 1 ;;
            owner-install) printf 'true\n' >"$capture/state"; return 1 ;;
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
    transition_receipt() {
      jq -e --arg wanted "$1" --arg op "$2" '
        .id == "claude:demo@m" and .receipt.op == $op and
        (.receipt.seq | type) == "number" and
        (if $wanted == "absent" then .receipt.installed == false and .receipt.state == null
        else .receipt.installed == true and .receipt.state == $wanted end)
      ' "$transition_journal" >/dev/null
    }
    transition_baseline() {
      mkdir -p "${baseline%/*}" "$capture/pass"
      jq -cn --arg value "$1" '{_initialized:{claude:true},"claude:demo@m":{value:$value}}' >"$baseline"
    }
    fleet_capture_collect() {
      local state
      case $(cat "$capture/state" 2>/dev/null || :) in
        true) state=enabled ;;
        false) state=disabled ;;
        *) state=absent ;;
      esac
      jq -cn --arg state "$state" '
        {trusted:true,claude:{"anchor@other":{value:"enabled",marketplace:"other",user_scope:true}}}
        | if $state == "absent" then . else
            .claude["demo@m"] = {value:$state,marketplace:"m",user_scope:true}
          end'
    }
    transition_prepare() {
      fleet_capture_pass_prepare "$ROUNDHOUSE_FLEET_STORE" mac \
        "$(jq -cn --arg state "$1" '{plugins:{demo:{state:$state,marketplace:"m"}}}')" \
        true true "$capture/pass" "$ROUNDHOUSE_FLEET_STORE" >"$capture/pass.log"
      [ "$fleet_capture_authoritative" = true ] || fail "owner change pass was not authoritative"
      : >"$capture/actions"
    }

    if section_part 1; then
    # A successful uninstall still owns the absence after a failed or no-op install.
    for install_behavior in fail noop; do
      fleet_run_plugin_refreshed=
      fleet_run_resolved_sha=fixture
      : >"$capture/intents"
      printf 'true\n' >"$capture/state"
      if fleet_run_plugin_reinstall demo@m previous >/dev/null 2>&1; then
        fail "reinstall reported success without installing ($install_behavior)"
      fi
      transition_receipt absent uninstall || fail "reinstall lost its completed uninstall ($install_behavior)"
      jq -e '.intent == null' "$transition_journal" >/dev/null ||
        fail "unchanged install did not clear its intent"
      jq -es '
        length == 2 and
        .[0].op == "uninstall" and .[1].op == "install" and
        (map(.op_id | strings | select(length > 0)) | unique | length) == 2 and
        (.[0].seq < .[1].seq)
      ' "$capture/intents" >/dev/null || fail "reinstall verbs did not have fresh intents in sequence"
    done

    # A failed uninstall that leaves the plugin cannot own a later owner removal.
    (
      rm -f "$transition_journal"
      printf 'true\n' >"$capture/state"
      uninstall_behavior=fail
      install_behavior=install
      fleet_run_plugin_refreshed=
      reinstall_status=0
      : >"$capture/actions"
      fleet_run_plugin_reinstall demo@m previous >/dev/null 2>&1 || reinstall_status=$?
      grep -Fqx uninstall "$capture/actions" || fail "reinstall did not attempt uninstall"
      [ "$reinstall_status" = 75 ] && [ "$(cat "$capture/state")" = true ] ||
        fail "failed uninstall did not leave the plugin installed with failure status"
      [ ! -e "$transition_journal" ] || fail "failed uninstall left an absent transition receipt or intent"

      rm "$capture/state"
      transition_baseline enabled
      transition_prepare enabled
      if ! grep -Fqx plugins.demo "$capture/pass/capture-skip"; then
        transition_apply enabled 0
      fi
      [ ! -e "$capture/state" ] && ! grep -Fqx install "$capture/actions" ||
        fail "the next pass reinstalled the plugin the owner removed"
      assert_contains "$(cat "$capture/pass.log")" 'claude:demo@m removed locally'
      grep -Fqx plugins.demo "$capture/pass/capture-skip" ||
        fail "the next pass did not hold the owner's removal after a failed uninstall"
    )

    # Only a successful install can own the disabled state it left behind.
    for install_behavior in disabled disabled-error; do
      rm -f "$transition_journal"
      fleet_run_plugin_refreshed=
      printf 'true\n' >"$capture/state"
      reinstall_status=0
      fleet_run_plugin_reinstall demo@m previous >/dev/null 2>&1 || reinstall_status=$?
      case $install_behavior in
        disabled) [ "$reinstall_status" = 0 ] || fail "verified disabled reinstall failed" ;;
        disabled-error) [ "$reinstall_status" = 74 ] || fail "failed reinstall lost its exit status" ;;
      esac
      [ "$(cat "$capture/state")" = false ] || fail "reinstall changed the fixture's disabled state"
      case $install_behavior in
        disabled)
          transition_receipt disabled install || fail "reinstall lost its verified disabled state"
          jq -e '.intent == null' "$transition_journal" >/dev/null || fail "verified reinstall left intent" ;;
        disabled-error)
          transition_receipt absent uninstall || fail "failed reinstall erased the verified uninstall"
          jq -e '.intent.op == "install"' "$transition_journal" >/dev/null ||
            fail "failed reinstall credited the installed plugin" ;;
      esac
    done
    unset install_behavior

    # Install succeeds, but the failed disable neither erases the install nor owns a disable.
    rm -f "$transition_journal" "$capture/state"
    transition_apply disabled 74
    transition_receipt enabled install || fail "failed disable erased the install receipt"
    jq -e '.intent == null' "$transition_journal" >/dev/null || fail "unchanged disable left intent"

    # Retry the disable after an interrupted first pass and then let the third pass converge.
    previous=$(cat "$transition_journal")
    transition_apply disabled 74
    [ "$(cat "$transition_journal")" = "$previous" ] || fail "failed retry changed the install receipt"
    fleet_run_plugin_refreshed=
    fleet_run_plugin_reinstall demo@m previous >/dev/null 2>&1 ||
      fail "composed retry could not refresh changed bytes"
    transition_apply disabled 74
    transition_receipt enabled install || fail "reinstall did not verify the intermediate enable"
    disable_behavior=disable
    transition_apply disabled 0
    transition_receipt disabled disable || fail "successful retry did not replace the intermediate state"
    disable_behavior=fail

    # A fresh install that starts disabled owns that state even if an enable no-ops.
    rm -f "$transition_journal" "$capture/state"
    install_behavior=disabled
    fleet_run_approve_plugin_hooks() { :; }
    fleet_run_codex_hooks_scoped() { :; }
    transition_apply enabled 74
    transition_receipt disabled install || fail "no-op enable lost the install's verified disabled state"

    # A failed standalone state verb must not hide the owner's next edit.
    for wanted in enabled disabled; do
      rm -f "$transition_journal"
      case $wanted in
        enabled) printf 'false\n' >"$capture/state" ;;
        disabled) printf 'true\n' >"$capture/state" ;;
      esac
      transition_apply "$wanted" 74
      [ ! -e "$transition_journal" ] || fail "unchanged $wanted request left a receipt or intent"
    done
    fi

    for install_part in 2 3; do
      section_part "$install_part" || continue
      rm -f "$transition_journal" "$capture/state"
      transition_baseline absent
      transition_prepare enabled
      if [ "$install_part" = 3 ]; then
        install_behavior=owner-install
      else
        install_behavior=fail
      fi
      transition_apply enabled 74
      grep -Fqx install "$capture/actions" || fail "failed-install fixture did not run install"
      if [ "$install_behavior" = fail ]; then
        printf 'true\n' >"$capture/state"
      else
        [ "$(cat "$capture/state")" = true ] || fail "owner install fixture did not change the state"
      fi
      transition_prepare absent
      if ! grep -Fqx plugins.demo "$capture/pass/capture-skip"; then
        transition_apply absent 0
      fi
      [ -e "$capture/state" ] && ! grep -Fqx uninstall "$capture/actions" ||
        fail "A1 failed install ($install_behavior) let the next tombstone uninstall the owner's plugin"
      if [ "$install_behavior" = fail ]; then
        assert_contains "$(cat "$capture/pass.log")" 'claude:demo@m added locally'
      else
        jq -e '.receipt == null and .intent.op == "install"' "$transition_journal" >/dev/null ||
          fail "A1 a nonzero exit credited the owner install before the post-read"
        assert_contains "$(cat "$capture/pass.log")" 'claude:demo@m added locally'
      fi
    done

    if section_part 4; then
      transition_baseline enabled
      printf 'true\n' >"$capture/state"
      transition_prepare absent
      uninstall_behavior=fail
      transition_apply absent 75
      grep -Fqx uninstall "$capture/actions" || fail "failed tombstone fixture did not run uninstall"
      rm "$capture/state"
      transition_prepare enabled
      if ! grep -Fqx plugins.demo "$capture/pass/capture-skip"; then
        fleet_run_apply_item "$ROUNDHOUSE_FLEET_STORE" mac '{}' plugins.demo '"enabled"' '{}' || :
      fi
      [ ! -e "$capture/state" ] && ! grep -Fqx install "$capture/actions" ||
        fail "A1 failed tombstone let the next pass reinstall the owner's removed plugin"
      assert_contains "$(cat "$capture/pass.log")" 'claude:demo@m removed locally'
    fi

    if section_part 5; then
      transition_baseline enabled
      printf 'false\n' >"$capture/state"
      : >"$capture/owned"
      fleet_run_plugin_identity_matches() { [ -e "$capture/updated" ]; }
      bounded_verb() {
        [ "$3" = update ] || return 1
        if [ -e "$transition_journal" ] || [ -e "${baseline%/*}/agent-pending/claude.demo@m" ]; then
          : >"$capture/update-provenance"
        fi
        : >"$capture/updated"
      }
      fleet_plugins_claude_update_unowned '{}' m "$capture/owned" ||
        fail "same-state update did not run after the owner disabled the plugin"
      [ -e "$capture/updated" ] || fail "same-state update did not reach the manager"
      transition_prepare enabled
      [ "$(cat "$capture/state")" = false ] && grep -Fqx plugins.demo "$capture/pass/capture-skip" ||
        fail "Attack #3 same-state update allowed the owner-disabled plugin to re-enable"
      [ ! -e "$capture/update-provenance" ] && [ ! -e "$transition_journal" ] ||
        fail "Attack #3 same-state update wrote state provenance"
    fi

    if section_part 6; then
      rm -f "$transition_journal"
      transition_baseline absent
      printf 'true\n' >"$capture/state"
      legacy="${baseline%/*}/agent-pending/claude.demo@__unqualified__"
      mkdir -p "${legacy%/*}"
      printf '%s\n' '{"id":"claude:demo@__unqualified__","from":"absent","to":"enabled"}' >"$legacy"
      fleet_run_plugin_market() { printf '\n'; }
      transition_prepare absent
      if ! grep -Fqx plugins.demo "$capture/pass/capture-skip"; then
        fleet_run_apply_item "$ROUNDHOUSE_FLEET_STORE" mac '{}' plugins.demo '"absent"' '{}' || :
      fi
      [ -e "$capture/state" ] && ! grep -Fqx uninstall "$capture/actions" ||
        fail "legacy unqualified marker let a tombstone uninstall an owner plugin"
      [ ! -e "$legacy" ] && [ ! -e "${baseline%/*}/agent-journal/claude.demo@__unqualified__" ] ||
        fail "legacy unqualified marker was not retired without a journal key"
    fi

    if section_part 7; then
      transition_baseline enabled
      printf 'false\n' >"$capture/state"
      printf '%s\n' '{"claude:demo@m":true}' >"${baseline%/*}/agent-discard.json"
      mkdir -p "${transition_journal%/*}"
      jq -cn --arg home "$(cd "$CLAUDE_CONFIG_DIR" && pwd -P)" '{
        id:"claude:demo@m",home:$home,intent:{op:"disable",to:"disabled",
          from:{installed:true,state:"enabled"},op_id:"new-dead",pid:2147483647,start:"dead",seq:1}
      }' >"$transition_journal"
      transition_prepare absent
      grep -Fqx plugins.demo "$capture/pass/capture-skip" ||
        fail "an old discard let the fleet act on a newly interrupted operation"
      jq -e '.intent.op_id == "new-dead"' "$transition_journal" >/dev/null ||
        fail "an old discard cleared a newly interrupted operation"
    fi

    if section_part 8; then
      transition_baseline enabled
      printf '%s\n' '{"_initialized":{"claude":true},"claude:dupe@m1":{"value":"enabled"},"claude:dupe@m2":{"value":"disabled"}}' >"$baseline"
      legacy="${baseline%/*}/agent-pending/claude.dupe@__unqualified__"
      mkdir -p "${legacy%/*}"
      printf '%s\n' '{"id":"claude:dupe@__unqualified__","from":"absent","to":"enabled"}' >"$legacy"
      desired='{"plugins":{"dupe@m1":"enabled","dupe@m2":"absent"}}'
      observed='{"trusted":true,"claude":{"dupe@m1":{"value":"enabled","user_scope":true},"dupe@m2":{"value":"disabled","user_scope":true}}}'
      fleet_capture_prepare "$ROUNDHOUSE_FLEET_STORE" mac "$desired" "$observed" true true "$capture/pass"
      fleet_capture_rebaseline "$ROUNDHOUSE_FLEET_STORE" mac "$desired" "$observed" true
      fleet_capture_prepare "$ROUNDHOUSE_FLEET_STORE" mac "$desired" "$observed" true true "$capture/pass"
      jq -e '.["plugins.dupe@m2"] == "claude:dupe@m2"' <<<"$fleet_capture_skip" >/dev/null ||
        fail "agreement for one marketplace released a legacy hold on another"
    fi

    if section_part 9; then
      transition_baseline enabled
      printf 'false\n' >"$capture/state"
      fleet_host_name() { printf 'mac\n'; }
      transition_prepare enabled
      fleet_discard_command claude:demo@m
      discarded=$(cat "${baseline%/*}/agent-discard.json")
      (
        fleet_capture_collect() { printf '%s\n' '{"trusted":false,"claude":null,"retry":true}'; }
        transition_prepare_untrusted() {
          fleet_capture_pass_prepare "$ROUNDHOUSE_FLEET_STORE" mac \
            '{"plugins":{"demo":{"state":"enabled","marketplace":"m"}}}' \
            true true "$capture/pass" "$ROUNDHOUSE_FLEET_STORE"
        }
        transition_prepare_untrusted
        rm "$capture/state"
        transition_prepare_untrusted
      )
      transition_prepare enabled
      if ! grep -Fqx plugins.demo "$capture/pass/capture-skip"; then
        fleet_run_apply_item "$ROUNDHOUSE_FLEET_STORE" mac '{}' plugins.demo '"enabled"' '{}' || :
      fi
      [ ! -e "$capture/state" ] && ! grep -Fqx install "$capture/actions" &&
        grep -Fq 'claude:demo@m removed locally' "$capture/pass.log" ||
        fail "Attack #10 an old discard authorized reinstall after the owner's later removal"
      jq -e '.["claude:demo@m"] | .id == "claude:demo@m" and
        .observed == {installed:true,state:"disabled"} and (.seq | type == "number")' \
        <<<"$discarded" >/dev/null ||
        fail "Attack #10 discard did not bind the decision to the disabled state"
    fi

    if section_part 10; then
      transition_baseline absent
      fleet_capture_fingerprint >"${baseline%/*}/agent-fingerprint"
      printf 'true\n' >"$capture/state"
      transition_prepare absent
      grep -Fqx plugins.demo "$capture/pass/capture-skip" || fail "poll floor fixture did not hold the owner install"
      if fleet_capture_dirty; then fail "a standing hold defeated the poll floor"; fi
      mkdir -p "${transition_journal%/*}"
      jq -cn --arg home "$(cd "$CLAUDE_CONFIG_DIR" && pwd -P)" '{
        id:"claude:demo@m",home:$home,intent:{op:"uninstall",to:"absent",
          from:{installed:true,state:"enabled"},op_id:"dead",pid:2147483647,start:"dead",seq:1}
      }' >"$transition_journal"
      fleet_capture_dirty || fail "an unresolved intent did not wake the poll floor"
    fi

    if section_part 11; then
      transition_baseline absent
      printf '%s\n' '{"_initialized":{"claude":true},"plugins.demo":{"value":"absent"}}' >"$baseline"
      fleet_run_plugin_market() { printf '\n'; }
      fleet_run_qualify_plugin() { printf 'demo@m\n'; }
      fleet_run_approve_plugin_hooks() { :; }
      fleet_run_codex_hooks_scoped() { :; }
      fleet_run_installed_plugins() {
        local entries='{"anchor@other":[{"scope":"user"}]}'
        if [ -f "$capture/state" ]; then
          jq -c --arg id "demo@${replacement_market:-m}" '.[$id] = [{scope:"user"}]' <<<"$entries"
        else printf '%s\n' "$entries"; fi
      }
      fleet_capture_collect() {
        fleet_run_installed_plugins | jq -c '
          {trusted:true,claude:with_entries(.value = {value:"enabled",user_scope:true})}'
      }
      fleet_capture_pass_prepare "$ROUNDHOUSE_FLEET_STORE" mac '{"plugins":{"demo":"enabled"}}' \
        true true "$capture/pass" "$ROUNDHOUSE_FLEET_STORE"
      transition_apply enabled 0
      grep -Fqx install "$capture/actions" || fail "Attack #8 fixture did not install the bare plugin"
      replacement_market=m2
      fleet_capture_pass_prepare "$ROUNDHOUSE_FLEET_STORE" mac '{"plugins":{"demo":"enabled"}}' \
        true true "$capture/pass" "$ROUNDHOUSE_FLEET_STORE"
      replacement_held=false
      if grep -Fqx plugins.demo "$capture/pass/capture-skip"; then replacement_held=true; fi
      fleet_capture_pass_prepare "$ROUNDHOUSE_FLEET_STORE" mac '{"plugins":{"demo":"absent"}}' \
        true true "$capture/pass" "$ROUNDHOUSE_FLEET_STORE"
      if ! grep -Fqx plugins.demo "$capture/pass/capture-skip"; then
        fleet_run_apply_item "$ROUNDHOUSE_FLEET_STORE" mac '{}' plugins.demo '"absent"' '{}' || :
      fi
      [ "$replacement_held" = true ] && [ -e "$capture/state" ] &&
        ! grep -Fqx uninstall "$capture/actions" ||
        fail "Attack #8 a bare plugin's install evidence did not hold the owner's replacement against a tombstone"
    fi

    if section_part 12; then
      transition_baseline enabled
      printf 'false\n' >"$capture/state"
      mkdir -p "${transition_journal%/*}"
      printf '%s\n' '{"seq":1}' >"${baseline%/*}/agent-seq"
      jq -cn --arg home "$(cd "$CLAUDE_CONFIG_DIR" && pwd -P)" '{
        id:"claude:demo@m",home:$home,intent:{op:"disable",to:"disabled",
          from:{installed:true,state:"enabled"},op_id:"dead",pid:2147483647,start:"dead",seq:1}
      }' >"$transition_journal"
      fleet_host_name() { printf 'mac\n'; }
      transition_prepare enabled
      fleet_discard_command claude:demo@m
      fleet_capture_pass_prepare "$ROUNDHOUSE_FLEET_STORE" mac '{}' true true \
        "$capture/pass" "$ROUNDHOUSE_FLEET_STORE"
      jq -e 'index("claude:demo@m") != null' <<<"$fleet_capture_discards" >/dev/null ||
        fail "unmanaged discard fixture did not accept the bound disabled state"
      rm "$capture/state"
      fleet_capture_rebaseline "$ROUNDHOUSE_FLEET_STORE" mac '{}' "$(fleet_capture_collect)" true
      transition_prepare enabled
      grep -Fqx plugins.demo "$capture/pass/capture-skip" ||
        fail "an unmanaged discard settled a later owner removal and let the fleet reinstall it"
      jq -e '.intent.op_id == "dead"' "$transition_journal" >/dev/null &&
        jq -e '."claude:demo@m".value == "enabled"' "$baseline" >/dev/null ||
        fail "an unmanaged discard replaced the baseline or lost the intent after a different owner edit"
    fi

    if section_part 13; then
      transition_baseline disabled
      jq '."claude:demo@m".raced = true' "$baseline" >"$baseline.next"
      mv "$baseline.next" "$baseline"
      printf 'true\n' >"$capture/state"
      fleet_host_name() { printf 'mac\n'; }
      transition_prepare disabled
      fleet_discard_command claude:demo@m
      transition_prepare disabled
      install_behavior=fail
      fleet_run_resolved_sha=fixture
      if fleet_run_plugin_reinstall demo@m previous >/dev/null 2>&1; then
        fail "raced discard fixture's partial reinstall unexpectedly succeeded"
      fi
      [ "$(cat "$capture/actions")" = "$(printf 'uninstall\ninstall\n')" ] && [ ! -e "$capture/state" ] ||
        fail "raced discard fixture did not uninstall the plugin before the failed install"
      transition_prepare disabled
      if grep -Fqx plugins.demo "$capture/pass/capture-skip"; then
        fail "a discarded race held Roundhouse's verified removal after a failed reinstall"
      fi
      transition_receipt absent uninstall || fail "partial reinstall lost the verified removal receipt"
      install_behavior=install
      disable_behavior=disable
      transition_apply disabled 0
      [ "$(cat "$capture/state")" = false ] || fail "the next pass did not finish the discarded race's reinstall"
    fi

    if section_part 14; then
      transition_baseline absent
      printf '%s\n' '{"_initialized":{"claude":true}}' >"$baseline"
      printf 'true\n' >"$capture/state"
      mkdir -p "${transition_journal%/*}"
      printf '%s\n' '{"seq":1}' >"${baseline%/*}/agent-seq"
      jq -cn --arg home "$(cd "$CLAUDE_CONFIG_DIR" && pwd -P)" '{
        id:"claude:demo@m",home:$home,intent:{op:"install",to:"installed",
          from:{installed:false,state:null},op_id:"dead",pid:2147483647,start:"dead",seq:1}
      }' >"$transition_journal"
      fleet_host_name() { printf 'mac\n'; }
      transition_prepare absent
      fleet_discard_command claude:demo@m
      transition_prepare absent
      uninstall_behavior=fail
      status=0
      fleet_run_uninstall_plugin '{}' plugins.demo demo '{"state":"absent","marketplace":"m"}' || status=$?
      [ "$status" = 75 ] && [ "$(cat "$capture/actions")" = uninstall ] && [ -e "$capture/state" ] ||
        fail "interrupted discard fixture did not reach the no-effect uninstall"
      rm "$capture/state"
      transition_prepare enabled
      grep -Fqx plugins.demo "$capture/pass/capture-skip" ||
        fail "a failed discarded uninstall let the fleet reinstall after a later owner removal"
      jq -e '.intent.op_id == "dead"' "$transition_journal" >/dev/null ||
        fail "a no-effect discarded uninstall erased the original interrupted intent"
    fi
  )
fi
