# roundhouse — the guards and the doctor.
#
# §10.4, §10.6 and §10.7 of docs/specs/2026-08-06-dsc-storage-design-v2.md.
# Two kinds of thing live here and they share their predicates on purpose:
#
#   GUARDS   run in the publish path and REFUSE — the redaction sweep over the
#            commit range about to be pushed, and the private-remote first-push
#            gate. A guard that only reports is a comment.
#   DOCTOR   runs read-only and REPORTS. Every row exists because something was
#            observed to fail silently; a row that cannot fire is a row that
#            was never a check.
#
# Doctor prints one row per line, `ok` or `FINDING`, and exits 0 clean / 1 with
# findings. It changes nothing: a doctor that repairs is a second convergence
# path with no review gate in front of it.
#
# Sourced by scripts/roundhouse; carries definitions only.
# shellcheck shell=bash

# --- the range every guard reads ----------------------------------------------

fleet_push_range() {
  # `present(main@origin)..<target>` — what this host is about to publish, and
  # nothing that is already published. `present()` because the bare form errors
  # on a never-fetched store (§8.1), and the bare token `main` never appears.
  printf 'present(main@origin)..%s\n' "$1"
}

# --- §10.4 the redaction sweep, over the range and over descriptions ----------

fleet_sweep_range() {
  # fleet_sweep_range STORE REVSET — prints one line per finding, silent when
  # clean. Callers refuse on any output.
  #
  # A PER-COMMIT walk, never a range diff: a secret hand-written into
  # findings/ is snapshotted and signed by the next jj command, and deleting it
  # afterwards leaves the tree clean while the blob is still in the range about
  # to be pushed. A range diff elides exactly that create-then-delete.
  #
  # DESCRIPTIONS ARE SWEPT TOO, and they are the surface rev 1 could not see:
  # `roundhouse-intent` rides every roundhouse commit and an `outcome: resolved`
  # rationale rides a resolution, both signed and replicated, neither reachable
  # from a path-based sweep. fleet_vcs_trailers does not check them — it
  # collapses newlines so the block stays parseable and nothing more. This is
  # the enforcement point.
  # FAIL CLOSED ON AN UNREADABLE RANGE. Piping `jj log` straight into `while`
  # made a FAILED enumeration — a bad revset after a version bump, a race, a
  # corrupt store — produce an empty stream indistinguishable from a clean
  # sweep, so the caller published unswept history. Capture the exit and REFUSE
  # on nonzero (the callers refuse on any output, so a diagnostic line suffices,
  # and the nonzero return says the same to a caller that checks it).
  sweep_commits=$(mktemp "${TMPDIR:-/tmp}/roundhouse-sweep.XXXXXX") || return 65
  sweep_rc=0
  jj -R "$1" log -r "$2" --no-graph -T 'commit_id ++ "\n"' \
    >"$sweep_commits" 2>/dev/null || sweep_rc=$?
  [ "$sweep_rc" -eq 0 ] || {
    rm -f "$sweep_commits"
    printf 'the sweep could not enumerate %s (jj log exit %s); refusing rather than reading an empty range as swept clean\n' \
      "$2" "$sweep_rc"
    return 65
  }
  while IFS= read -r sweep_commit; do
      [ -n "$sweep_commit" ] || continue
      jj -R "$1" log -r "$sweep_commit" --no-graph -T 'description' 2>/dev/null |
        {
          sweep_line=0
          while IFS= read -r sweep_text; do
            sweep_line=$((sweep_line + 1))
            ! fleet_quote_is_secret "$sweep_text" ||
              printf '%s description line %s matches a secret class\n' \
                "$sweep_commit" "$sweep_line"
            # The 400-byte cap on replicated free text, applied where the free
            # text actually is: a rationale that does not fit belongs in
            # store.run/, not on the wire.
            case $sweep_text in
              roundhouse-*': '*)
                sweep_value=${sweep_text#*': '}
                [ "$(printf '%s' "$sweep_value" | wc -c | tr -d ' ')" \
                  -le "$fleet_replicated_cap" ] ||
                  printf '%s description line %s: trailer %s exceeds %s bytes\n' \
                    "$sweep_commit" "$sweep_line" "${sweep_text%%:*}" \
                    "$fleet_replicated_cap"
                ;;
            esac
          done
        }
      # `jj diff --name-only` refuses -T and prints paths relative to the
      # CALLER's directory, so it runs with cwd INSIDE the store or every name
      # comes back absolute. Measured on jj 0.44.
      (cd "$1" && jj diff -r "$sweep_commit" --name-only 2>/dev/null) |
        while IFS= read -r sweep_path; do
          case $sweep_path in
            findings/?* | alerts/?*) ;;
            *) continue ;;
          esac
          jj -R "$1" file show -r "$sweep_commit" "root:$sweep_path" 2>/dev/null |
            {
              sweep_line=0
              while IFS= read -r sweep_text; do
                sweep_line=$((sweep_line + 1))
                # The line number is §10.4's own promise: "names the file and
                # the line within it".
                ! fleet_quote_is_secret "$sweep_text" ||
                  printf '%s %s:%s matches a secret class\n' \
                    "$sweep_commit" "$sweep_path" "$sweep_line"
              done
            }
        done
    done <"$sweep_commits"
  rm -f "$sweep_commits"
}

fleet_sweep_gate() {
  # fleet_sweep_gate STORE TARGET — the publish-path half. A match REFUSES the
  # push (§10.4's remedy cannot un-publish, so before the wire is the only
  # workable moment) and names the recovery.
  sweep_found=$(fleet_sweep_range "$1" "$(fleet_push_range "$2")")
  [ -n "$sweep_found" ] || return 0
  printf 'roundhouse: refusing to publish; the redaction sweep matched (§10.4):\n' >&2
  printf '%s\n' "$sweep_found" >&2
  printf 'roundhouse: drop it from local history with `jj -R %s abandon -r <commit>` or `jj -R %s op restore %s`\n' \
    "$1" "$1" "$(cat "$(fleet_run_state_dir)/starting-operation" 2>/dev/null ||
      printf '<starting-operation>')" >&2
  return 65
}

# --- §10.6 the private-remote first-push gate ---------------------------------

fleet_posture_path() {
  # store.local/posture.yaml. The flag is one host's check of one host's
  # remote, which is why it belongs outside the tree: §2/§12 delete the
  # `meta/host.json` that carried it, and replicating it would invite a peer to
  # answer this host's question for it.
  fleet_instance_path store.local/posture.yaml
}

fleet_posture_get() {
  fleet_record_read "$(fleet_posture_path)" '{}' | jq -r --arg k "$1" '.[$k] // ""'
}

fleet_remote_url() {
  # jj-native, because §8.4 admits exactly two read-only git calls
  # (`ls-remote`, `verify-commit`) and `git remote get-url` is neither. The
  # rule was applied to the symlink row and not to this one; it applies here.
  jj -R "$1" git remote list 2>/dev/null |
    awk -v want="${2:-origin}" '$1 == want { print $2; exit }'
}

fleet_first_push_gate() {
  # fleet_first_push_gate STORE — no push to a remote whose visibility this host
  # has not verified FOR THAT REMOTE'S URL.
  #
  #   remote presence   `jj git remote list`, never `git remote get-url`
  #   verified posture   store.local/posture.yaml, never a file in the tree,
  #                      and KEYED ON THE URL rather than on `main@origin`
  #                      presence
  #
  # The old `present(main@origin)` short-circuit read "already pushed → not a
  # first push". But jj keys the tracking ref by remote NAME, not URL, so a
  # re-point (`fleet-set-remote` to a new URL) left `main@origin` naming the
  # OLD remote's tip — non-empty — and the gate returned 0, letting the first
  # push to a possibly-public new remote skip the §10.6 posture check entirely.
  # Visibility evidence belongs to the remote it was gathered against, so the
  # gate now passes only when the posture is verified AND recorded against the
  # remote URL currently configured. Steady-state pushes still pass with no
  # re-verification because the URL has not changed; a re-point invalidates the
  # posture (fleet-set-remote / fleet-verify-remote records the URL) and this
  # refuses until the new remote is proven private.
  fpg_url=$(fleet_remote_url "$1")
  [ -n "$fpg_url" ] || return 0
  [ "$(fleet_posture_get remote_visibility_verified)" = true ] &&
    [ "$(fleet_posture_get remote_visibility_url)" = "$fpg_url" ] && return 0
  printf 'roundhouse: first push requires a verified-private remote; run `roundhouse fleet-verify-remote` (posture: %s)\n' \
    "$(fleet_posture_get remote_visibility_reason || printf unchecked)" >&2
  return 65
}

fleet_remote_visibility_probe() (
  # fleet_remote_visibility_probe URL -> `<verified> <reason>` on stdout:
  # `true auth-required`, `false public`, or `false probe-inconclusive`.
  #
  # A FAILED PROBE IS NOT EVIDENCE OF PRIVACY. Only an authentication refusal
  # proves the remote is gated; unreachable, DNS failure and timeout are
  # inconclusive and must never satisfy the first-push gate. `git ls-remote` is
  # §6.1's own admitted call and moves no ref.
  #
  # ONE probe, called from both the verb below and from `fleet-add`, which
  # needs the same verdict about the same URL before it enrols anybody onto it.
  # A second copy of this three-way logic is a second thing to get wrong on the
  # one question that decides whether private topology reaches a public host.
  probe_url=$1
  probe_tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-visibility.XXXXXX") || return 70
  trap 'rm -rf "$probe_tmp"' EXIT HUP INT TERM
  probe_status=0
  if fleet_test_hook "${ROUNDHOUSE_FLEET_VISIBILITY_PROBE:-}"; then
    sh -c "$ROUNDHOUSE_FLEET_VISIBILITY_PROBE" >/dev/null 2>"$probe_tmp/probe.err" ||
      probe_status=$?
  else
    # Every credential path is closed: what answers here answers for anyone.
    GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/false \
      GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0='' \
      GIT_SSH_COMMAND='ssh -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityFile=/dev/null' \
      git ls-remote --heads -- "$probe_url" >/dev/null 2>"$probe_tmp/probe.err" ||
      probe_status=$?
  fi
  if [ "$probe_status" -eq 0 ]; then
    printf 'false public\n'
  elif grep -qE 'Authentication|Permission denied|401|403|could not read Username|terminal prompts disabled' \
    "$probe_tmp/probe.err"; then
    printf 'true auth-required\n'
  else
    printf 'false probe-inconclusive\n'
  fi
)

fleet_verify_remote_command() (
  # `roundhouse fleet-verify-remote` — the unauthenticated probe, and the
  # three-way verdict that makes it honest.
  fleet_run_env
  require_jq
  require_yq
  verify_store=$(fleet_store_path)
  verify_url=$(fleet_remote_url "$verify_store")
  [ -n "$verify_url" ] || {
    # The remedy, named. `fleet-init` creates the store but adds no remote —
    # only `fleet-set-remote` or an out-of-band `jj git clone` does — so host 1
    # following §12's runbook hit this exit with nothing to act on.
    printf 'roundhouse: the fleet store has no origin remote to verify; run `roundhouse fleet-set-remote URL` first (it adds the remote as well as moving it)\n' >&2
    exit 69
  }
  verify_verdict=$(fleet_remote_visibility_probe "$verify_url")
  verify_verified=${verify_verdict%% *}
  verify_reason=${verify_verdict#* }
  # The URL the verdict was gathered against is recorded WITH it: §10.6's gate
  # keys on the URL, so evidence for remote A must not open the gate for remote
  # B. A verdict for a URL that is not the current origin reads as unverified.
  fleet_record_write "$(fleet_posture_path)" \
    "$(fleet_record_read "$(fleet_posture_path)" '{}' |
      jq -c --argjson v "$verify_verified" --arg r "$verify_reason" \
        --arg u "$verify_url" --arg at "$(fleet_now)" \
        '.remote_visibility_verified = $v | .remote_visibility_reason = $r |
         .remote_visibility_url = $u | .checked_at = $at')"
  [ "$verify_verified" = true ] || {
    case $verify_reason in
      public)
        printf 'roundhouse: the store remote answers unauthenticated reads (publicly readable); refusing to publish to it\n' >&2
        ;;
      *)
        printf 'roundhouse: the visibility probe was inconclusive; an unreachable remote is not evidence of privacy\n' >&2
        ;;
    esac
    exit 65
  }
  printf 'roundhouse: %s requires authentication; the first push is permitted\n' \
    "$verify_url"
)

fleet_set_remote_command() (
  # `roundhouse fleet-set-remote URL` — move this store to a new remote. Never
  # edits config.json: the store's origin is jj's, and this command prints what
  # a human still has to do on every other host.
  #
  # THE ORDER IS THE DESIGN, carried verbatim from v1 because each step defends
  # against the failure of the one after it:
  #
  #   the alert is committed BEFORE the push, so a crash between the two still
  #   leaves the store carrying the record of how it got where it went — that
  #   record is the fleet's only in-band notice of the move, and writing it
  #   afterwards loses it exactly when the store has already moved;
  #
  #   a FAILED push is the one case still under this process's control, so the
  #   alert commit is rolled back and origin is left where it was — otherwise
  #   local main permanently claims a move that never happened and republishes
  #   it to the OLD remote on the next run.
  fleet_run_env
  require_jq
  require_yq
  move_url=$1
  fleet_validate_fetch_url "$move_url" || {
    printf 'roundhouse: unsupported fleet store URL: %s\n' "$move_url" >&2
    exit 64
  }
  move_store=$(fleet_store_path)
  move_host=$(fleet_host_name)
  move_old=$(fleet_remote_url "$move_store")
  [ "$move_url" != "$move_old" ] || {
    printf 'roundhouse: the store already points at %s\n' "$move_url" >&2
    exit 64
  }
  move_refs=$(git ls-remote --heads -- "$move_url" 2>/dev/null) || {
    # An unreachable target is a fleet outage waiting to happen, not a move.
    printf 'roundhouse: the new fleet store remote is not reachable: %s\n' \
      "$move_url" >&2
    exit 69
  }

  # §7.5, and it is a COMPARISON rather than a presence check: the threat is
  # two fleets pointed at one remote, and only this host's own store id tells
  # them apart. An EMPTY remote is the ordinary case and passes; a populated
  # one has to be this same store.
  if [ -n "$move_refs" ]; then
    move_refused=
    if printf '%s\n' "$move_refs" | grep -q '[[:space:]]refs/heads/main$'; then
      jj -R "$move_store" git remote add roundhouse-move "$move_url" >/dev/null 2>&1 ||
        jj -R "$move_store" git remote set-url roundhouse-move "$move_url" >/dev/null
      if jj -R "$move_store" git fetch --remote roundhouse-move >/dev/null 2>&1; then
        # §7.5 as a REVSET comparison: the genesis commit id of what the remote
        # carries. A marker file could be copied into a hostile store; a genesis
        # commit cannot be produced without producing that commit.
        move_token=$(fleet_store_id_at "$move_store" \
          'present(main@roundhouse-move)')
        if [ -z "$move_token" ]; then
          move_refused='the remote exists and is not a roundhouse fleet store'
        elif [ "$move_token" != "$(fleet_store_id "$move_store")" ]; then
          move_refused='the remote carries a DIFFERENT fleet store'
        fi
      else
        move_refused='the remote main could not be read'
      fi
      jj -R "$move_store" git remote remove roundhouse-move >/dev/null 2>&1 || :
    else
      move_refused='the remote exists and is not a roundhouse fleet store'
    fi
    [ -z "$move_refused" ] || {
      printf 'roundhouse: %s — choose a different remote or clear it (origin unchanged)\n' \
        "$move_refused" >&2
      exit 65
    }
  fi

  move_base=$(fleet_vcs_heads_local "$move_store" | head -1)
  [ -n "$move_base" ] || {
    printf 'roundhouse: the store has no main to move\n' >&2
    exit 65
  }
  fleet_alert_write "$move_store" "$move_host" store-moved store-moved \
    "the fleet store remote moved to $move_url; re-point every host at it" || {
    printf 'roundhouse: refusing the move: the alert trips the redaction floor (§10.4)\n' >&2
    exit 65
  }
  jj -R "$move_store" describe -r @ -m "move the store remote to $move_url

$(fleet_vcs_trailers "$move_host" migration 'store remote moved' -)" >/dev/null
  jj -R "$move_store" bookmark set main \
    -r "$(jj -R "$move_store" log -r @ --no-graph -T 'commit_id')" >/dev/null

  if [ -n "$move_old" ]; then
    jj -R "$move_store" git remote set-url origin "$move_url" >/dev/null
  else
    jj -R "$move_store" git remote add origin "$move_url" >/dev/null
  fi
  # §10.4 OVER THE WHOLE HISTORY, locally, before the operator bothers verifying
  # the remote: this remote has never seen any of it, so the incremental range
  # guard inside publish (`present(main@origin)..<target>`) would miss a secret
  # already in history. A match — or a sweep that could not read the history —
  # rolls the whole move back (origin unchanged); a store whose history cannot
  # be swept clean is not a store to re-point.
  move_sweep_rc=0
  move_sweep=$(fleet_sweep_range "$move_store" "::$move_base") || move_sweep_rc=$?
  if [ "$move_sweep_rc" -ne 0 ] || [ -n "$move_sweep" ]; then
    printf 'roundhouse: refusing the move; the redaction sweep matched or could not read the history this remote has never seen (§10.4):\n' >&2
    printf '%s\n' "$move_sweep" >&2
    jj -R "$move_store" bookmark set main -r "$move_base" >/dev/null 2>&1 || :
    if [ -n "$move_old" ]; then
      jj -R "$move_store" git remote set-url origin "$move_old" >/dev/null 2>&1 || :
    else
      jj -R "$move_store" git remote remove origin >/dev/null 2>&1 || :
    fi
    exit 65
  fi
  # THE FIRST PUSH TO THIS REMOTE IS DEFERRED, not attempted here — the fix for
  # both faces of this command. A fresh ADD (host 1's genesis bootstrap, no
  # origin yet) and a genuine MOVE (re-point to a new URL) are each a FIRST push
  # to this remote under §10.6, and pushing inline could not satisfy the gate
  # yet: the remote's visibility is unverified until fleet-verify-remote runs,
  # and there is a chicken-and-egg — the gate refuses, the old rollback removed
  # the just-added remote, and fleet-verify-remote then had NO remote to probe
  # (the documented bootstrap could not be executed). So the remote is left
  # LANDED, the posture is INVALIDATED for the new URL, and the push waits for
  # the next fleet-run/fleet-add after verification. §10.6's gate keys on the
  # URL, so it refuses to publish to the new remote until it is proven private
  # — which is what closes the re-point skip too.
  fleet_record_write "$(fleet_posture_path)" \
    "$(fleet_record_read "$(fleet_posture_path)" '{}' |
      jq -c --arg at "$(fleet_now)" \
        '.remote_visibility_verified = false |
         .remote_visibility_reason = "remote-changed" |
         del(.remote_visibility_url) | .checked_at = $at')"
  printf 'roundhouse: the fleet store remote is now %s (added locally; nothing pushed yet)\n' "$move_url"
  printf 'roundhouse: run `roundhouse fleet-verify-remote`, then `roundhouse fleet-run` to publish the first push to it; re-point every other host at it too. This command never edits config.json\n'
)

# --- §10.6 store-symlink detection, over the jj tree --------------------------

fleet_store_symlinks() {
  # fleet_store_symlinks STORE REV — re-implemented, for two reasons. The v1
  # walk was a raw `git ls-tree -r <status-ref>` (a banned git call against a
  # deleted ref), and the P0-3 config migration puts a symlink into $HOME
  # INSIDE `.jj/`, so the detector has to be scoped to the TRACKED tree rather
  # than to the directory or it fires on jj's own plumbing.
  #
  # `file_type` is a 0-argument TreeEntry method, so it reads as a keyword;
  # `path` likewise, and it is not decoration — a bare `jj file list` prints
  # paths relative to the CALLER's directory, so from anywhere else every line
  # comes back as `../../../store/hosts/vireo.yaml`. Measured on jj 0.44.
  jj -R "$1" file list -r "$2" -T 'if(file_type == "symlink", path ++ "\n")' \
    2>/dev/null
}

fleet_store_host_local_files() {
  # The shipped tripwire, scoped the same way: a host-local file that got
  # committed into the tracked tree. Identity and trust material is host-local
  # by design (KTD16) and a copy inside the store is a copy on every machine.
  jj -R "$1" file list -r "$2" -T 'path ++ "\n"' 2>/dev/null |
    grep -E '(^|/)(identity\.yaml|local\.yaml|allowed_signers|krl|posture\.yaml)$' ||
    true
}

# --- §5.1.3 the hook trust gate -----------------------------------------------

fleet_hook_trust() {
  # fleet_hook_trust STORE HOST DEFS NAME — the re-implemented gate. It reads
  # the desired `hooks:` map and `definitions.yaml` AT THE REVIEWED REF (its
  # caller folds them from a `jj file show` export, so there is no status
  # branch, no `materialized/`, no `schema` key and no raw git anywhere in the
  # path), resolves the hook through §5.1.3's two delivery forms, and answers
  # one question: may this hook run on this host?
  #
  #   plugin-delivered   trusted when this host HOLDS THE PLUGIN'S APPROVAL —
  #                      `plugins.<plugin>` is in this host's applied/ record,
  #                      which it can only be after passing this host's own
  #                      review, canary and apply gates. Approving the plugin
  #                      approves its hooks (§5.1.3), so the hook rides the
  #                      install and needs nothing else.
  #   standalone         NEVER trusted, and there is deliberately no install
  #                      path for one anywhere in this system. A standalone
  #                      hook is arbitrary code from a source outside the
  #                      plugin trust flow; it reports `enabled_but_untrusted`
  #                      and is held.
  #
  # Prints `trusted <why>` / `enabled_but_untrusted <why>`, exit 0 / 1.
  #
  # ponytail: no allowlist for standalone sources, because trusting one would
  # have to install it and no harness-settings writer exists — `config_files`
  # declares ownership, not values (§5/§6). Add the allowlist the day a
  # settings-file writer lands, not before: a trust flag that installs nothing
  # would journal `applied` for a hook that never ran.
  hook_surface=$(fleet_resolve_surface "$3" hooks "$4") || return 1
  hook_delivery=$(printf '%s\n' "$hook_surface" | jq -r '.delivery')
  if [ "$hook_delivery" = plugin ]; then
    hook_plugin=$(printf '%s\n' "$hook_surface" | jq -r '.plugin')
    [ -z "$(fleet_applied_digest "$1" "$2" "plugins.$hook_plugin")" ] || {
      printf 'trusted rides plugins.%s, whose approval this host holds\n' "$hook_plugin"
      return 0
    }
    printf 'enabled_but_untrusted this host does not hold an approval for plugins.%s\n' \
      "$hook_plugin"
    return 1
  fi
  printf 'enabled_but_untrusted standalone hook source %s is not reviewed on this host\n' \
    "$(printf '%s\n' "$hook_surface" | jq -r '.source // "unknown"')"
  return 1
}

# --- §10.7 the doctor ---------------------------------------------------------

fleet_doctor_days_ago() {
  # ISO8601 Z, N days back. BSD and GNU date disagree about the flag, so both
  # are tried rather than one being assumed.
  date -u -v-"$1"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
    date -u -d "$1 days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
    printf '1970-01-01T00:00:00Z\n'
}

fleet_doctor_row() {
  # fleet_doctor_row ok|finding NAME DETAIL. Findings are counted in a FILE
  # because half these rows are produced inside pipelines, and a counter
  # incremented in a subshell is a counter that always reads zero.
  case $1 in
    ok) printf 'ok       %-26s %s\n' "$2" "$3" ;;
    *)
      printf 'FINDING  %-26s %s\n' "$2" "$3"
      printf '%s\n' "$2" >>"$fleet_doctor_findings"
      ;;
  esac
}

doctor_root_owned() {
  # True when <path> is acceptably root-owned. On a real host that means
  # owner root and nothing else — a same-user-owned trust file is precisely the
  # §7.9 attack. The self-check cannot produce root-owned files unprivileged, so
  # under ROUNDHOUSE_SELFTEST self-ownership is accepted too, exactly the
  # real-host/fixture split check_enrolled_trust_file already draws — but gated
  # on selftest so a real host's same-user file stays a finding.
  doctor_ro_owner=$(file_owner "$1")
  [ "$doctor_ro_owner" = root ] && return 0
  [ "${ROUNDHOUSE_SELFTEST:-0}" = 1 ] && [ "$doctor_ro_owner" = "$(id -un)" ]
}

fleet_doctor_check() {
  # fleet_doctor_check NAME OK-DETAIL FINDING-DETAIL < findings-on-stdin —
  # the shape most rows have: some producer prints nothing when clean.
  doctor_out=$(cat)
  if [ -z "$doctor_out" ]; then
    fleet_doctor_row ok "$1" "$2"
  else
    fleet_doctor_row finding "$1" "$3: $(printf '%s' "$doctor_out" | tr '\n' ';' |
      cut -c1-300)"
  fi
}

fleet_doctor_command() (
  # `roundhouse fleet-doctor` — read-only. One row per line, exit 1 on any
  # finding, and never a repair: a doctor that fixes things is a second
  # convergence path with no review gate in front of it.
  fleet_run_env
  require_jq
  require_yq
  doctor_store=$(fleet_store_path)
  doctor_host=$(fleet_host_name)
  doctor_tmp=$(mktemp -d "${TMPDIR:-/tmp}/roundhouse-doctor.XXXXXX")
  trap 'rm -rf "$doctor_tmp"' EXIT HUP INT TERM
  fleet_doctor_findings=$doctor_tmp/findings
  : >"$fleet_doctor_findings"

  # --- prerequisites, and the versions every version-sensitive row rests on ---
  doctor_missing=
  for doctor_tool in jj jq yq; do
    command -v "$doctor_tool" >/dev/null 2>&1 ||
      doctor_missing="$doctor_missing $doctor_tool"
  done
  if [ -n "$doctor_missing" ]; then
    fleet_doctor_row finding tools "missing:$doctor_missing"
  else
    fleet_doctor_row ok tools "jj $(jj --version 2>/dev/null | awk '{print $2}'), jq $(jq --version 2>/dev/null), yq $(yq --version 2>/dev/null | awk '{print $NF}')"
  fi

  if [ ! -d "$doctor_store/.jj" ]; then
    fleet_doctor_row finding store "no fleet store at $doctor_store; run \`roundhouse fleet-init\`"
    exit 1
  fi

  # --- §7.5 the genesis pin: a REVSET comparison, never a file read ---
  # The root commit of this store's ancestry, compared against identity.yaml's
  # store_id. A marker file could be *contained* by a hostile store; a genesis
  # commit id cannot, because producing a store with that genesis means
  # producing that commit — unforgeable rather than merely secret.
  if fleet_store_id_assert "$doctor_store" 2>"$doctor_tmp/id"; then
    doctor_id=$(fleet_store_id "$doctor_store")
    if [ -n "$doctor_id" ]; then
      fleet_doctor_row ok genesis-pin "$doctor_id"
    else
      fleet_doctor_row finding genesis-pin \
        "$doctor_store has no history; run \`roundhouse fleet-enroll\` — the roster commit IS the genesis"
    fi
  else
    fleet_doctor_row finding genesis-pin "$(tr '\n' ' ' <"$doctor_tmp/id")"
  fi

  # --- §3.1/§3.2 the pins, by EFFECTIVE value ---
  # Effective values only, never file contents: jj 0.44 migrates a written
  # `.jj/repo/config.toml` into ~/.config/jj/repos/<hash>/, so a read that does
  # not share the XDG root of the write answers about a different repo.
  fleet_pins_drift "$doctor_store" |
    fleet_doctor_check config-pins 'jj and git pins match §3.1/§3.2' 'drift'

  # --- R4: `[signing]` present implies the key file it names exists ---
  if fleet_signing_ready "$doctor_store" 2>"$doctor_tmp/signing"; then
    fleet_doctor_row ok signing-key \
      "$(jj -R "$doctor_store" config get signing.key 2>/dev/null ||
        printf 'unset (host not enrolled)')"
  else
    fleet_doctor_row finding signing-key "$(tr '\n' ' ' <"$doctor_tmp/signing")"
  fi

  # --- §7.1 trust roots, read fresh per invocation ---
  doctor_signers=$(fleet_allowed_signers_path)
  if doctor_krl=$(fleet_trust_krl 2>"$doctor_tmp/krlerr"); then
    fleet_doctor_row ok trust-roots "$doctor_signers, $doctor_krl"
    # A revocation-list path that does not RESOLVE makes ssh-keygen report
    # every signature `bad` — indistinguishable from mass revocation, and it is
    # a typo. Resolution is checked above; emptiness is reported here, because
    # an empty KRL is legitimate (nothing revoked yet) and a MISSING one is not.
    if [ -s "$doctor_krl" ]; then
      fleet_doctor_row ok krl "$(wc -c <"$doctor_krl" | tr -d ' ') bytes"
    else
      fleet_doctor_row ok krl 'present and empty (nothing revoked)'
    fi
  else
    # §7.7: a host between fleet-init and fleet-enroll can verify nothing, and
    # holding everything would brick §12's own bootstrap. The run SKIPS the
    # signature gate there — silently, which is exactly what this row exists to
    # stop being silent about.
    doctor_krl=
    fleet_doctor_row finding signature-skip \
      "$(tr '\n' ' ' <"$doctor_tmp/krlerr"); every commit converges UNVERIFIED — run \`roundhouse fleet-enroll\`"
  fi

  # --- §7.9 the privileged materialization lane and its custody ---
  # Where NO privileged lane is configured the row stays OK with a DEGRADED
  # note: §7.9 mandates the seamless fallback and says doctor "reports rather
  # than fails" on it, and where the user has passwordless sudo root ownership
  # collapses to same-user anyway — a FINDING there would be permanently red on
  # most hosts and train the operator to ignore the column.
  # But once trustd IS installed, its whole value is root ownership: an
  # installed helper whose $TRUST files are still same-user is trustd DEFEATED,
  # and that IS a finding.
  doctor_trust_root=$(fleet_trust_root)
  if doctor_lane=$(fleet_trust_privileged); then
    doctor_lane_bad=
    for doctor_lane_f in allowed_signers reviewed-ref generation krl; do
      [ -f "$doctor_trust_root/$doctor_lane_f" ] || continue
      doctor_root_owned "$doctor_trust_root/$doctor_lane_f" ||
        doctor_lane_bad="$doctor_lane_f is $(file_owner "$doctor_trust_root/$doctor_lane_f")-owned"
    done
    if [ -z "$doctor_lane_bad" ]; then
      fleet_doctor_row ok privileged-lane "$doctor_lane (\$TRUST root-owned)"
    else
      fleet_doctor_row finding privileged-lane \
        "trustd is installed at $doctor_lane but $doctor_lane_bad, not root — same-user custody defeats it (§7.9)"
    fi
  else
    # No privileged lane NOW. Distinguish a host that NEVER had one (OK,
    # seamless — §7.9's degraded rung) from one that WAS privileged and has been
    # forced back to same-user custody (residual 7). trustd writes a root-owned
    # `privileged` marker in the root-owned $TRUST on every root apply; a
    # same-user attacker who unlinks the binary to force the downgrade cannot
    # delete that marker out of the root-owned directory, so its presence with no
    # lane is the forced-degrade FINDING. The same-user degrade branch never
    # writes it, so a never-privileged host stays cleanly OK.
    doctor_marker=$doctor_trust_root/privileged
    if [ -f "$doctor_marker" ] && doctor_root_owned "$doctor_marker"; then
      fleet_doctor_row finding privileged-lane \
        "was root-owned but the trustd lane is now absent — forced degrade back to same-user custody, re-enabling persistence past revocation (§7.9 residual 7); reinstall the trustd lane"
    else
      fleet_doctor_row ok privileged-lane \
        "DEGRADED: no privileged lane, so $doctor_signers is same-user writable — that buys no protection against this machine's own compromise, only against PERSISTENCE PAST REVOCATION (§7.9)"
    fi
  fi

  # trustd's OWN binary AND THE TREE IT SOURCES must be root-owned where it is
  # installed: a same-user-writable trustd — or a same-user-writable library or
  # toolchain co-located beside it — is trustd defeated, because root then runs
  # attacker code. Assert the whole root-owned prefix, not just the binary.
  doctor_trustd_bin=$fleet_trust_prefix/roundhouse-trustd
  ! fleet_test_hook "${ROUNDHOUSE_TRUSTD:-}" || doctor_trustd_bin=$ROUNDHOUSE_TRUSTD
  if [ ! -e "$doctor_trustd_bin" ]; then
    fleet_doctor_row ok trustd-binary 'not installed (degraded rung, §7.9)'
  else
    doctor_trustd_dir=$(dirname "$doctor_trustd_bin")
    doctor_trustd_bad=
    for doctor_trustd_p in "$doctor_trustd_bin" "$doctor_trustd_dir/roundhouse" \
      "$doctor_trustd_dir/lib" "$doctor_trustd_dir/toolchain"; do
      [ -e "$doctor_trustd_p" ] || continue
      doctor_root_owned "$doctor_trustd_p" ||
        doctor_trustd_bad="$doctor_trustd_p is $(file_owner "$doctor_trustd_p")-owned"
    done
    if [ -z "$doctor_trustd_bad" ]; then
      fleet_doctor_row ok trustd-binary "$doctor_trustd_bin (root-owned tree)"
    else
      fleet_doctor_row finding trustd-binary \
        "$doctor_trustd_bad, not root; a same-user-writable trustd tree is trustd defeated (§7.9)"
    fi
  fi

  doctor_heads=$(fleet_vcs_heads_local "$doctor_store" | grep . || true)
  doctor_origin=$(fleet_vcs_head_origin "$doctor_store")
  doctor_target=$(printf '%s\n' "$doctor_heads" | head -1)
  # The range rows read EVERY head, not the first one: a conflicted bookmark
  # has two, and a row that inspects one of them answers about half the store.
  # The tree rows below take a single commit because a tree is a tree.
  doctor_range=$(fleet_push_range 'heads(bookmarks(exact:"main"))')

  # The reviewed tree, exported once: several rows below read the layers, and
  # `jj file show` per file per row would read the same commit five times.
  : >"$doctor_tmp/hosts"
  if [ -n "$doctor_target" ]; then
    fleet_run_export "$doctor_store" "$doctor_target" "$doctor_tmp/layers"
    fleet_vcs_enrolled_hosts "$doctor_store" "$doctor_target" >"$doctor_tmp/hosts"
    grep -Fqx "$doctor_host" "$doctor_tmp/hosts" ||
      printf '%s\n' "$doctor_host" >>"$doctor_tmp/hosts"
  fi

  # --- §7.1/§7.3 the gate, observed to reject ---
  if [ -n "$doctor_target" ] && [ -n "$doctor_krl" ]; then
    doctor_reviewed=$doctor_tmp/reviewed-roster
    fleet_trust_roster_at_head "$doctor_store" "$doctor_target" "$doctor_reviewed"
    for doctor_head in $doctor_heads; do
      doctor_hold=$(fleet_trust_commit_hold "$doctor_store" "$doctor_head" \
        "$doctor_tmp/rw.$doctor_head" "$doctor_reviewed") ||
        printf '%s %s\n' "$doctor_head" "$doctor_hold"
    done | fleet_doctor_check head-signature \
      'every main head verifies good against the roster at its own parents, and its principal matches its committer' \
      'a head does not verify'

    # RATCHET REPLAY — the gate itself, asserted rather than assumed: every
    # commit in reviewed-ref..head verifies against ITS OWN roster-at-parents,
    # and its timestamp does not predate its parent's. ONE walk feeds both
    # rows: deriving a roster is several jj invocations per commit, and walking
    # the range twice doubled the doctor's cost for nothing.
    #
    # With no reviewed-ref yet, the range falls back to what this host is about
    # to publish rather than the whole history — replaying from genesis on
    # every doctor run is a cost that grows forever, which is what §7.11's
    # checkpoints exist to bound.
    doctor_replay_from=$(fleet_trust_reviewed_ref)
    if [ -n "$doctor_replay_from" ] &&
      jj -R "$doctor_store" log -r "$doctor_replay_from" --no-graph -T '""' \
        >/dev/null 2>&1; then
      doctor_replay="$doctor_replay_from..$doctor_target"
    else
      doctor_replay=$doctor_range
    fi
    : >"$doctor_tmp/replay"
    jj -R "$doctor_store" log -r "$doctor_replay" --no-graph \
      -T 'commit_id ++ "\n"' 2>/dev/null | while IFS= read -r doctor_replay_c; do
      [ -n "$doctor_replay_c" ] || continue
      doctor_replay_bad=$(fleet_trust_commit_hold "$doctor_store" \
        "$doctor_replay_c" "$doctor_tmp/rp.$doctor_replay_c" "$doctor_reviewed") ||
        printf '%s %s\n' "$doctor_replay_c" "$doctor_replay_bad"
    done >"$doctor_tmp/replay"
    grep -v ' timestamp ' "$doctor_tmp/replay" | fleet_doctor_check ratchet-replay \
      'every commit in the verified range verifies against its own roster-at-parents' \
      'a commit in the verified range does not replay'
    grep ' timestamp ' "$doctor_tmp/replay" | fleet_doctor_check monotonicity \
      'no commit in the verified range predates its parent' \
      'a commit is backdated'

    # MATERIALIZATION DIGEST — a hand-edited materialized file is precisely the
    # self-enrollment signature. Mismatch is an alert and a full hold, NEVER a
    # repair: a doctor that fixes things is a second convergence path with no
    # review gate in front of it.
    fleet_trust_materialization_drift "$doctor_store" |
      fleet_doctor_check materialization-digest \
        'the materialized allowed_signers is byte-identical to the roster the ratchet derives' \
        'materialized roster drift'

    # §7.1's cross-check, and it is NOT a gate: if it ever disagrees with jj,
    # delete it rather than trusting it.
    doctor_git=ok
    git -C "$doctor_store" \
      -c gpg.ssh.program=ssh-keygen \
      -c gpg.ssh.allowedSignersFile="$doctor_signers" \
      -c gpg.ssh.revocationFile="$doctor_krl" \
      verify-commit "$doctor_target" >/dev/null 2>&1 || doctor_git=disagrees
    if [ "$doctor_git" = ok ]; then
      fleet_doctor_row ok git-cross-check 'git verify-commit agrees with jj on the head'
    else
      fleet_doctor_row finding git-cross-check \
        "git verify-commit rejects a head jj accepts ($doctor_target)"
    fi

    # §7.3's path->identity table AND §7.1 rule 6's class boundary, over what
    # this host is about to publish.
    fleet_run_signature_holds "$doctor_store" "$doctor_range" "$doctor_tmp/hosts" \
      "$doctor_tmp/layers" "$doctor_host" "$doctor_reviewed" "$doctor_tmp/rs" \
      2>/dev/null |
      fleet_doctor_check path-identity \
        'every path in the push range was authored by an identity permitted to write it' \
        'held'
  fi

  # --- §7.1 the roster, which is hand-editable and therefore hand-breakable ---
  doctor_roster=$doctor_store/$fleet_trust_roster_file
  if [ -f "$doctor_roster" ]; then
    {
      # Every entry has a well-formed principal and key; every enrolled host has
      # exactly one entry; no durable entry lacks a hosts/<h>.yaml; generation
      # is present.
      yq -r '.generation // ""' "$doctor_roster" 2>/dev/null | grep -q '[0-9]' ||
        printf 'generation: is absent\n'
      fleet_trust_entries "$doctor_roster" | while read -r doctor_re doctor_rc doctor_rp doctor_ra doctor_rb doctor_rat doctor_rch doctor_rk doctor_rv; do
        case $doctor_rp in
          *@?*) ;;
          *) printf '%s has no well-formed principal\n' "$doctor_re" ;;
        esac
        case $doctor_rk in
          ssh-* | ecdsa-* | sk-*) ;;
          *) printf '%s has no usable key\n' "$doctor_re" ;;
        esac
        [ -n "$doctor_rv" ] || printf '%s has a truncated key\n' "$doctor_re"
        [ "$doctor_rc" != durable ] ||
          [ -e "$doctor_tmp/layers/hosts/$doctor_re.yaml" ] ||
          [ -d "$doctor_tmp/layers/hosts/$doctor_re" ] ||
          printf 'durable %s has no hosts/%s.yaml\n' "$doctor_re" "$doctor_re"
      done
      fleet_trust_entries "$doctor_roster" | awk '{ print $1 }' |
        LC_ALL=C sort | uniq -d |
        while IFS= read -r doctor_dup; do
          [ -z "$doctor_dup" ] ||
            printf '%s appears in more than one class\n' "$doctor_dup"
        done
    } | fleet_doctor_check roster-coherence \
      'every roster entry is well formed and every durable member has a host file' \
      'roster'

    # Every roster line carries namespaces="git" and NO time options. Time
    # options in a file jj reads are evaluated at wall clock and are therefore
    # retroactive; the namespace is what stops an enrollment proof being
    # replayed as a commit signature.
    if [ -f "$doctor_signers" ]; then
      awk '
        $0 !~ /namespaces="git"/ { print "line " NR " carries no namespaces=\"git\"" }
        /valid-before=|valid-after=/ { print "line " NR " carries a TIME OPTION, which is retroactive" }
      ' "$doctor_signers" | fleet_doctor_check roster-lines \
        'every materialized roster line carries namespaces="git" and no time options' \
        'roster line'
    fi

    # GENERATION, the other half of the rollback defence: same custody as
    # reviewed-ref because it does the same job. In the store it is
    # attacker-controlled by construction.
    doctor_gen=$(fleet_trust_generation "$doctor_roster")
    doctor_gen_seen=$(fleet_trust_seen_generation)
    if [ -f "$(fleet_trust_root)/generation" ] &&
      [ "$doctor_gen" -ge "$doctor_gen_seen" ]; then
      fleet_doctor_row ok generation \
        "$doctor_gen (high-water mark $doctor_gen_seen, $(fleet_trust_root)/generation)"
    elif [ ! -f "$(fleet_trust_root)/generation" ]; then
      fleet_doctor_row finding generation \
        "no generation high-water mark at $(fleet_trust_root)/generation; a rollback would be undetectable on this host"
    else
      fleet_doctor_row finding generation \
        "roster generation $doctor_gen is BELOW this host's last-seen $doctor_gen_seen (§7.12.3)"
    fi

    # CLASS ENFORCEMENT, asserted rather than left in prose: an `ephemeral`
    # principal touching a fleet-shared path, and one touching the roster
    # itself, are both refused. "The class is the security boundary" is
    # otherwise the only rule with nothing observing it.
    {
      ! fleet_trust_class_allows ephemeral fleet.yaml ||
        printf 'a leaf was permitted to write fleet.yaml\n'
      ! fleet_trust_class_allows ephemeral "$fleet_trust_roster_file" ||
        printf 'a leaf was permitted to sponsor\n'
      fleet_trust_class_allows ephemeral "journal/$doctor_host/x.yaml" ||
        printf 'a leaf was refused its own evidence path\n'
      fleet_trust_class_allows durable fleet.yaml ||
        printf 'a durable member was refused a fleet layer\n'
      # DEFAULT-DENY, observed: the empty class is what the every-parent
      # intersection produces for a principal whose class DISAGREED across
      # parents, and it used to be granted full durable authority.
      ! fleet_trust_class_allows '' fleet.yaml ||
        printf 'an unnamed class was granted a fleet layer\n'
      ! fleet_trust_class_allows unknown-class "$fleet_trust_roster_file" ||
        printf 'an unrecognised class was permitted to sponsor\n'
    } | fleet_doctor_check class-enforcement \
      'a leaf is refused every fleet-shared path and permitted its own evidence' \
      'class rule'

    # SOAK: a fleet-layer write signed by a key enrolled inside the window is
    # held. The soak is what makes the enroll-then-write race strictly WORSE for
    # an attacker than not enrolling at all.
    {
      [ "$(fleet_trust_soak_hours durable tofu)" = 72 ] ||
        printf 'tofu enrollment does not take the 72h soak\n'
      [ "$(fleet_trust_soak_hours durable known_hosts)" = 24 ] ||
        printf 'known_hosts enrollment does not take the 24h soak\n'
      [ "$(fleet_trust_soak_hours ephemeral runtime)" = 0 ] ||
        printf 'a leaf takes a soak, which it has nothing to delay\n'
      # `channel_auth: genesis` is honoured ONLY in the genesis commit's own
      # context. Anywhere else it is a self-asserted field switching its own
      # soak off, which is §7.12.1's control 5 bypassed by typing a word.
      [ "$(fleet_trust_soak_hours durable genesis genesis)" = 0 ] ||
        printf 'the genesis commit took a soak, and it has no counterparty\n'
      [ "$(fleet_trust_soak_hours durable genesis)" = 24 ] ||
        printf 'channel_auth genesis switched the soak off outside the genesis commit\n'
      # An absent enrolled_at means MAXIMUM caution, not none.
      printf 'nostamp@fixture durable - known_hosts\n' >"$doctor_tmp/soak.nostamp"
      fleet_trust_soak_open "$doctor_tmp/soak.nostamp" nostamp@fixture \
        "$(fleet_now)" ||
        printf 'a member carrying no enrolled_at was not held by the soak\n'
      # Observed to BITE, on a fixture: a key enrolled one hour ago is inside
      # its window and a key enrolled a year ago is not.
      printf 'fresh@fixture durable %s tofu\nold@fixture durable %s known_hosts\n' \
        "$(fleet_now)" "$(fleet_doctor_days_ago 365)" >"$doctor_tmp/soak.classes"
      fleet_trust_soak_open "$doctor_tmp/soak.classes" fresh@fixture \
        "$(fleet_now)" ||
        printf 'a key enrolled just now was NOT held by the soak\n'
      ! fleet_trust_soak_open "$doctor_tmp/soak.classes" old@fixture \
        "$(fleet_now)" ||
        printf 'a key enrolled a year ago was held by the soak\n'
      doctor_soak_now=$(fleet_now)
      yq -r '(.durable // {}) | to_entries[] |
        .key + " " + (.value.enrolled_at // "-")' "$doctor_roster" 2>/dev/null |
        while read -r doctor_se doctor_sat; do
          [ "$doctor_sat" != - ] ||
            printf '%s carries no enrolled_at, so its soak cannot be evaluated\n' \
              "$doctor_se"
          [ "$doctor_sat" = - ] || [ "$doctor_sat" \< "$doctor_soak_now" ] ||
            printf '%s is enrolled in the future\n' "$doctor_se"
        done
    } | fleet_doctor_check soak \
      'the soak class table is the one §7.3a states, and every member carries a past enrolled_at' \
      'soak'
  else
    fleet_doctor_row finding roster-coherence \
      "no roster at $fleet_trust_roster_file; run \`roundhouse fleet-enroll\` (the roster commit IS the genesis)"
  fi

  # --- §7.10.1 checkpoints are TAGS, and §7.11.2's archive is MANDATORY ---
  # A bookmark confers no immutability — measured on properly isolated sibling
  # commits, the same rewrite succeeded. And a re-root without a published
  # archive is byte-for-byte a rollback attack to every offline host, so the
  # producing side is checked here rather than only the consuming side, which
  # catches it after a host is already stuck.
  if [ -d "$doctor_store/checkpoints" ] &&
    [ -n "$(ls "$doctor_store/checkpoints" 2>/dev/null)" ]; then
    doctor_ckpt=$(jj -R "$doctor_store" log -r 'tags()' --no-graph \
      -T 'commit_id ++ "\n"' 2>/dev/null | grep -c . || printf '0')
    if [ "$doctor_ckpt" -gt 0 ]; then
      fleet_doctor_row ok checkpoint-tags \
        "$doctor_ckpt tagged checkpoint(s); tags make them and all their ancestors immutable for free"
    else
      fleet_doctor_row finding checkpoint-tags \
        'checkpoints/ carries records but no tag names any commit; a bookmark confers NO immutability (§7.10.1)'
    fi
    if [ -n "$(git -C "$doctor_store" for-each-ref --format='%(refname)' \
      'refs/roundhouse/archive/*' 2>/dev/null)" ]; then
      fleet_doctor_row ok archive-present \
        "$(git -C "$doctor_store" for-each-ref --format='%(refname)' \
          'refs/roundhouse/archive/*' 2>/dev/null | tr '\n' ' ')"
    else
      fleet_doctor_row finding archive-present \
        'no refs/roundhouse/archive/* ref; a re-root without one is indistinguishable from the §7.12.3 rollback attack'
    fi
  fi

  # --- §8.1 the revsets, and the real "no bare main" check ---
  doctor_revsets=
  for doctor_revset in 'heads(bookmarks(exact:"main"))' 'present(main@origin)' \
    'present(main@origin)..heads(bookmarks(exact:"main"))' \
    '(conflicts() & @-) ~ ::remote_bookmarks()' \
    '@ & (heads(bookmarks(exact:"main")) | present(main@origin))'; do
    jj -R "$doctor_store" log -r "$doctor_revset" --no-graph -T '""' >/dev/null 2>&1 ||
      doctor_revsets="$doctor_revsets [$doctor_revset]"
  done
  if [ -z "$doctor_revsets" ]; then
    fleet_doctor_row ok revsets 'every revset the run uses resolves on this repository'
  else
    fleet_doctor_row finding revsets "these did not resolve:$doctor_revsets"
  fi

  # --- §8.1 the working-copy invariant ---
  if [ -z "$(jj -R "$doctor_store" log \
    -r '@ & (heads(bookmarks(exact:"main")) | present(main@origin))' \
    --no-graph -T 'commit_id')" ]; then
    fleet_doctor_row ok working-copy '@ is not a target of main'
  else
    fleet_doctor_row finding working-copy \
      '@ sits ON a main target; a hand edit there rewrites the commit the bookmark names'
  fi

  # --- the brick that recurs: an undescribed ancestor of the bookmark ---
  jj -R "$doctor_store" log -r "$doctor_range" --no-graph \
    -T 'if(description, "", commit_id ++ "\n")' 2>/dev/null |
    grep . |
    fleet_doctor_check undescribed \
      'every commit in the push range carries a description' \
      'an undescribed commit refuses to push forever'

  # --- §8.4 publication policy ---
  jj -R "$doctor_store" log -r "conflicts() & $doctor_range" --no-graph \
    -T 'commit_id ++ "\n"' 2>/dev/null |
    fleet_doctor_check conflicts 'no conflicted commit in the push range' \
      'a conflicted commit would be published'
  for doctor_head in ${doctor_heads:-}; do
    fleet_vcs_git_conflict_paths "$doctor_store" "$doctor_head"
  done | fleet_doctor_check conflict-paths \
    'no materialized conflict path in the git tree at any head' \
    'an inbound published conflict is present'

  # --- jj#9571: a raw `git push` from the colocated repo bypasses every gate --
  # jj's own refusal is not self-enforcing, and every guard above lives in
  # `jj git push`. Comparing the two sides' commits does not work as a check —
  # jj auto-imports git refs in a colocated repo, so a divergence heals itself
  # before anything can observe it. What IS stable, because jj imports no git
  # config at all, is whether the colocated `.git` is set up to make a raw push
  # easy: a push refspec, a `push.default` that publishes matching branches, or
  # a git branch that is not the one bookmark this design has.
  {
    doctor_refspec=$(git -C "$doctor_store" config --get remote.origin.push 2>/dev/null || true)
    [ -z "$doctor_refspec" ] ||
      printf 'remote.origin.push is %s\n' "$doctor_refspec"
    [ "$(git -C "$doctor_store" config --get push.default 2>/dev/null || true)" != matching ] ||
      printf 'push.default is matching\n'
    git -C "$doctor_store" for-each-ref --format='%(refname:lstrip=2)' refs/heads \
      2>/dev/null | grep -vx main | sed 's/^/an extra git branch: /' || true
  } | fleet_doctor_check raw-git-push \
    'the colocated .git carries no push refspec and no branch beyond main' \
    'a raw git push would bypass every publication guard (jj#9571)'

  # --- §10.6 the tripwires over the TRACKED tree ---
  if [ -n "$doctor_target" ]; then
    fleet_store_symlinks "$doctor_store" "$doctor_target" |
      fleet_doctor_check store-symlinks 'no symlink in the tracked store tree' \
        'a symlink in the store is a link out of it'
    fleet_store_host_local_files "$doctor_store" "$doctor_target" |
      fleet_doctor_check host-local-leak \
        'no host-local file inside the tracked store tree' \
        'host-local material is committed'
  fi

  # --- §10.4 the sweep, both surfaces ---
  doctor_sweep=$(fleet_sweep_range "$doctor_store" "$doctor_range")
  printf '%s' "$doctor_sweep" | grep ' description ' |
    fleet_doctor_check description-sweep \
      'no secret and no over-cap trailer in a commit description in the push range' \
      'a replicated description trips the redaction floor'
  printf '%s' "$doctor_sweep" | grep -v ' description ' | grep . |
    fleet_doctor_check findings-sweep \
      'no secret under findings/ or alerts/ in the push range' \
      'a replicated file trips the redaction floor'

  # --- §5/§8.2b the trailer block: the resolver's only evidence ---
  jj -R "$doctor_store" log -r "$doctor_range" --no-graph \
    -T 'if(description.contains("roundhouse-host: "), "", commit_id ++ "\n")' \
    2>/dev/null | grep . |
    fleet_doctor_check trailers \
      'every commit in the push range carries the §5 trailer block' \
      'a run that stops writing trailers degrades every future conflict to an escalation'

  # --- §6.1(a) the poll floor is the propagation mechanism ---
  if [ -z "$(fleet_remote_url "$doctor_store")" ]; then
    fleet_doctor_row ok poll-floor 'no origin remote configured; nothing to poll'
  else
    doctor_ls=$(git -C "$doctor_store" ls-remote origin refs/heads/main 2>/dev/null |
      awk 'NR == 1 { print $1; exit }') || doctor_ls=
    if [ -z "$doctor_ls" ] && [ -n "$doctor_origin" ]; then
      fleet_doctor_row finding poll-floor \
        'ls-remote answered nothing while main@origin exists; the fleet degrades to the 12h cadence silently'
    elif [ -n "$doctor_ls" ] && [ -n "$doctor_origin" ] && [ "$doctor_ls" != "$doctor_origin" ]; then
      fleet_doctor_row ok poll-floor "remote is ahead of main@origin ($doctor_ls)"
    else
      fleet_doctor_row ok poll-floor "ls-remote is comparable to main@origin"
    fi
  fi

  # --- §10.6 the private-remote posture ---
  doctor_posture=$(fleet_posture_get remote_visibility_reason)
  if [ -z "$(fleet_remote_url "$doctor_store")" ]; then
    fleet_doctor_row ok remote-posture 'no origin remote configured'
  elif fleet_first_push_gate "$doctor_store" 2>/dev/null; then
    fleet_doctor_row ok remote-posture \
      "${doctor_posture:-already published; the first-push gate no longer applies}"
  else
    fleet_doctor_row finding remote-posture \
      "the first push is gated and the remote's visibility is ${doctor_posture:-unchecked}; run \`roundhouse fleet-verify-remote\`"
  fi

  # --- §10.6 the run lock, and the threshold that must never read the fast interval
  doctor_stale=$(fleet_run_stale_after "$doctor_store" "$doctor_host")
  doctor_lock=$(fleet_lock_path)
  if [ ! -d "$doctor_lock" ]; then
    fleet_doctor_row ok run-lock "no lock held; stale threshold ${doctor_stale}s (two full cadences)"
  else
    doctor_age=$(fleet_lock_age_seconds "$doctor_lock" || printf '')
    # An unknown age is a FINDING, not "held for unknowns, under the
    # threshold". A lock whose meta.json is missing or unparsable carries no
    # evidence of a live runner, and reading it as fresh made this row print
    # `ok` about the exact state that wedges every future run.
    if [ -z "$doctor_age" ]; then
      fleet_doctor_row finding run-lock \
        "$doctor_lock has no readable meta.json, so its age is unknown; confirm no live runner, then remove it"
    elif [ "$doctor_age" -gt "$doctor_stale" ]; then
      fleet_doctor_row finding run-lock \
        "$doctor_lock is ${doctor_age}s old, past the ${doctor_stale}s threshold; confirm no live runner, then remove it"
    else
      fleet_doctor_row ok run-lock "held for ${doctor_age}s, under the ${doctor_stale}s threshold"
    fi
  fi

  # --- §3.2 no rewrite subcommand without a message flag ---
  # ui.editor is pinned, but a pin is one migration away from being lost and an
  # editor prompt in a scheduled run hangs a machine nobody is sitting at.
  awk '/\\$/ { sub(/\\$/, " "); joined = joined $0; next } { print joined $0; joined = "" }' \
    "$script_dir/roundhouse" "$script_dir"/lib/*.sh 2>/dev/null |
    grep -vE '^ *#' |
    grep -E 'jj +((-R|--config|--at-operation) +[^ ]+ +)*(describe|commit)([ "]|$)' |
    grep -v -- ' -m ' |
    fleet_doctor_check rewrite-messages \
      'every rewrite subcommand in the source carries a message flag' \
      'a rewrite could open an editor'

  # --- §14: no DSC record carries a schema key ---
  { find "$doctor_store" -type f \( -name '*.yaml' -o -name '*.json' \) \
    -not -path "$doctor_store/.jj/*" -not -path "$doctor_store/.git/*" \
    -exec grep -lE '^ *schema(_version)?:' {} +
  find "$(fleet_run_state_dir)" "$(fleet_instance_path store.local)" -type f \
    -exec grep -lE '^ *schema(_version)?:' {} + 2>/dev/null || true
  } 2>/dev/null | fleet_doctor_check banned-keys \
    'no DSC record carries a banned version key' \
    'a banned key survived'

  # --- §7.2 the digest pipeline, recomputed on THIS host ---
  # Not a pinned constant: what this catches is a yq/jq behaviour change here,
  # and the cross-host comparison is `fleet-doctor --all` over ssh. The two
  # equalities are the two §7.2 promises — reader's choice and line endings.
  doctor_scalar=$(printf '"enabled"\n' | fleet_value_digest plugins.probe)
  doctor_map=$(printf '{"state":"enabled"}\n' | fleet_value_digest plugins.probe)
  doctor_crlf=$(printf '{"state":"enabled"}\r\n' | fleet_value_digest plugins.probe)
  if [ "$doctor_scalar" = "$doctor_map" ] && [ "$doctor_map" = "$doctor_crlf" ]; then
    fleet_doctor_row ok digest "scalar, map and CRLF forms agree ($doctor_scalar)"
  else
    fleet_doctor_row finding digest \
      "the §7.2 pipeline no longer normalizes on this host: $doctor_scalar / $doctor_map / $doctor_crlf"
  fi

  # --- §10.8 both directions of the revert-signature predicate ---
  # The revert row and its MIRROR. Rev 5's change-ID gate broke the promotion
  # side and nothing caught it, which is why both are observed here.
  doctor_revert=ok
  printf 'applied D1\napplied D2\n' | fleet_vcs_revert_signature D1 ||
    doctor_revert='a revert would auto-pass on a stale verdict'
  ! printf 'applied D1\napplied D1\n' | fleet_vcs_revert_signature D1 ||
    doctor_revert='a promotion would be re-reviewed'
  if [ "$doctor_revert" = ok ]; then
    fleet_doctor_row ok revert-signature \
      'a revert is re-reviewed and a promotion applies silently'
  else
    fleet_doctor_row finding revert-signature "$doctor_revert"
  fi

  # --- §10.8 every canary bypass in the last 30 days ---
  doctor_overrides=$(fleet_journal_entries "$doctor_store" "$doctor_host" 2>/dev/null |
    jq -r --arg since "$(fleet_doctor_days_ago 30)" \
      'select(.override == "canary" and .at >= $since) |
       "\(.at) \(.item)"' 2>/dev/null || true)
  if [ -z "$doctor_overrides" ]; then
    fleet_doctor_row ok canary-overrides 'no --now bypass on this host in the last 30 days'
  else
    # Reported, never a finding by itself: `--now` is a legitimate,
    # journaled, bound bypass. What must never happen is that it goes
    # uncounted, because an uncounted bypass becomes routine.
    fleet_doctor_row ok canary-overrides \
      "$(printf '%s' "$doctor_overrides" | grep -c .) in the last 30 days: $(printf '%s' "$doctor_overrides" | tr '\n' ';')"
  fi

  # --- rows that need the reviewed layers ---
  if [ -d "$doctor_tmp/layers" ]; then
    doctor_fold=$(fleet_fold "$doctor_tmp/layers" "$doctor_host" 2>/dev/null || printf '{}')
    doctor_defs=$(fleet_definitions_load "$doctor_tmp/layers" 2>/dev/null || printf '{}')

    # §5: every field that reaches ssh_config or a peer URL, through the one
    # predicate. An unvalidated `tailnet_name` is ssh_config injection.
    while IFS= read -r doctor_peer; do
      [ -n "$doctor_peer" ] || continue
      doctor_facts=$(fleet_host_facts "$doctor_tmp/layers" "$doctor_peer" 2>/dev/null || printf '{}')
      fleet_validate_ssh_field "$doctor_peer" ||
        printf 'hosts/%s: the host name itself\n' "$doctor_peer"
      for doctor_field in hostname tailnet_name user; do
        doctor_value=$(printf '%s\n' "$doctor_facts" |
          jq -r --arg f "$doctor_field" '.[$f] // ""')
        [ -n "$doctor_value" ] || continue
        fleet_validate_ssh_field "$doctor_value" ||
          printf 'hosts/%s: %s\n' "$doctor_peer" "$doctor_field"
      done
    done <"$doctor_tmp/hosts" |
      fleet_doctor_check ssh-fields \
        'every hostname, tailnet name, user and host name passes the fetch-URL predicate' \
        'ssh_config injection'

    # §5: chezmoi co-ownership is DETECTED, never required — and a key that
    # both systems write is a fight neither wins.
    fleet_config_coowned "$doctor_fold" 2>/dev/null |
      fleet_doctor_check chezmoi 'no managed key is also written by chezmoi' \
        'co-ownership has re-emerged'

    # §5.1.3: what the hook gate is holding, by name. This is the one behaviour
    # that carried over intact from the deleted gate.
    printf '%s\n' "$doctor_fold" | jq -r '(.hooks // {}) | keys[]' 2>/dev/null |
      while IFS= read -r doctor_hook; do
        [ -n "$doctor_hook" ] || continue
        fleet_hook_trust "$doctor_store" "$doctor_host" "$doctor_defs" "$doctor_hook" |
          sed -n "s/^enabled_but_untrusted /hooks.$doctor_hook: /p"
      done | fleet_doctor_check hooks \
      'every enabled hook rides a plugin whose approval this host holds' \
      'enabled_but_untrusted'

    # B-1/R7: two sources of machine truth, and nothing reconciles them. ONE
    # ROW comparing the overlapping fields — never a converter, because absorb
    # pipelines are what this design exists to delete.
    #
    # DECIDED, and held open through phase 10 before being settled here: the
    # row stays `platform` and `groups` ONLY. `hostname`, `user` and
    # `package_managers` also overlap, and they are deliberately not compared —
    # each has a legitimate reason to differ (a config.json `expected_user`
    # that documents an intended login, a host whose managers the fold resolves
    # per platform), so rows for them would fire on correct configurations and
    # teach the reader to ignore this check. Widening it is a decision about
    # B-1, not a bug fix: the boundary says config.json stays hand-edited and
    # host-local for the privilege lane, and unifying the two representations
    # is a separate project.
    doctor_self=$(fleet_host_facts "$doctor_tmp/layers" "$doctor_host" 2>/dev/null || printf '{}')
    for doctor_field in platform groups; do
      doctor_store_value=$(printf '%s\n' "$doctor_self" |
        jq -cS --arg f "$doctor_field" '.[$f] // null')
      doctor_config_value=$(jq -cS --arg h "$doctor_host" --arg f "$doctor_field" \
        '.machines[$h][$f] // null' "$(config_path)" 2>/dev/null || printf null)
      [ "$doctor_store_value" = "$doctor_config_value" ] ||
        [ "$doctor_config_value" = null ] ||
        printf '%s: store %s, config.json %s\n' "$doctor_field" \
          "$doctor_store_value" "$doctor_config_value"
    done | fleet_doctor_check machine-truth \
      'hosts/<name>.yaml and config.json .machines agree on the overlapping facts' \
      'the two sources of machine truth have drifted (B-1)'
  fi

  # --- clocks, because every canary wait is only as good as them ---
  doctor_skew=$(for doctor_journal in "$doctor_store"/journal/*/; do
    [ -d "$doctor_journal" ] || continue
    doctor_peer=${doctor_journal%/}
    doctor_peer=${doctor_peer##*/}
    fleet_journal_entries "$doctor_store" "$doctor_peer" 2>/dev/null |
      jq -r --arg now "$(fleet_now)" \
        'select(.at != null) | select((.at | fromdateiso8601) - ($now | fromdateiso8601) > 300) |
         "\(.at)"' 2>/dev/null | sed "s|^|$doctor_peer |"
  done)
  if [ -z "$doctor_skew" ]; then
    fleet_doctor_row ok clock 'no peer journal timestamp is more than 5 minutes ahead of this host'
  else
    fleet_doctor_row finding clock \
      "a peer journal is ahead of this clock: $(printf '%s' "$doctor_skew" | tr '\n' ';')"
  fi

  doctor_count=$(grep -c . "$fleet_doctor_findings" || true)
  if [ "$doctor_count" -eq 0 ]; then
    printf 'roundhouse: fleet-doctor clean\n'
    exit 0
  fi
  printf 'roundhouse: fleet-doctor found %s\n' "$doctor_count"
  exit 1
)
