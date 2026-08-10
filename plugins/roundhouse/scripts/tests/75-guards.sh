# roundhouse self-check — §10.4/§10.6's guards: the hook trust gate, the
# redaction sweep's predicates, the private-remote posture, the stale-lock
# threshold and the adopt-pin containment.
#
# No jj and no store repository: everything here is pure file, JSON and
# arithmetic logic, which is the seam §12.1 draws. The repository half — the
# sweep over a real push range, symlink detection over the jj tree and every
# doctor row — lives in tests/94-jj-doctor.sh.
#
# Sourced by scripts/test-roundhouse in a fixed order; not a
# standalone test file. See that driver for why.
# shellcheck shell=bash

if [ -n "$fleet_fixture_yq" ]; then
  printf 'guards: §5.1.3 hook trust, §10.4 sweep, §10.6 posture and containment\n'
  (
    set -eu
    PATH=$fleet_fixture_path
    export PATH
    # shellcheck source=/dev/null
    ROUNDHOUSE_LIB_ONLY=1 . "$cli"

    guard_root="$tmp/guards"
    guard_store="$guard_root/store"
    mkdir -p "$guard_store/hosts"
    ROUNDHOUSE_FLEET_STORE=$guard_store
    HOME="$guard_root/home"
    export ROUNDHOUSE_FLEET_STORE HOME
    mkdir -p "$HOME"

    # --- every verb's path-building argument, through ONE predicate ---
    # `fleet-add` — which only ADDS — carried this guard; `fleet-remove`, which
    # runs `rm -f "$store/hosts/$1.yaml"` and `rm -rf "$store/hosts/$1"`, did
    # not, and dispatch accepts one argument INCLUDING the empty string.
    # Confirmed in a scratch tree: `fleet-remove ''` resolved to
    # `rm -rf "$store/hosts/"` and took every host file in the store, and
    # `fleet-remove ../../SECRET` deleted a sibling directory outside the store
    # entirely — with enough `../` that reaches ~/.ssh and the node signing key.
    for guard_bad in '' . .. ../../SECRET 'hosts/vireo' 'a b' 'a;rm -rf /' \
      '$(id)' 'vireo/../../etc'; do
      ! fleet_host_name_ok "$guard_bad" ||
        fail "fleet_host_name_ok accepted a path-escaping host name: '$guard_bad'"
    done
    for guard_ok in vireo wren-2 build-x7f2 host.example a_b; do
      fleet_host_name_ok "$guard_ok" ||
        fail "fleet_host_name_ok refused a legitimate host name: '$guard_ok'"
    done
    # …and it is the predicate the deleting verb actually calls. Asserted on
    # the SOURCE, because the destructive path cannot be exercised safely.
    cli_function_body fleet_remove_command | grep -q 'fleet_host_name_ok' ||
      fail "fleet-remove does not validate HOST before it builds an rm path"
    cli_function_body fleet_remove_command |
      awk '/fleet_host_name_ok/ { seen = 1 } / rm -/ { exit(seen ? 0 : 1) }' ||
      fail "fleet-remove reaches an rm before it validates HOST"
    for guard_verb in fleet_add_command fleet_renew_command \
      fleet_reconstitute_command; do
      cli_function_body "$guard_verb" | grep -q 'fleet_host_name_ok' ||
        fail "$guard_verb does not validate its host argument"
    done

    # Whole hours or nothing: `--ttl 8h` used to print "renewed for 8hh", exit
    # 0, and set valid_before to NOW — a leaf enrolled already expired.
    for guard_bad in '' 8h -1 1.5 'a' '24 '; do
      ! fleet_enroll_hours_ok "$guard_bad" ||
        fail "fleet_enroll_hours_ok accepted a non-numeric TTL: '$guard_bad'"
      ! fleet_enroll_deadline "$guard_bad" >/dev/null 2>&1 ||
        fail "fleet_enroll_deadline minted a window from '$guard_bad'"
    done
    fleet_enroll_deadline 24 >/dev/null ||
      fail "fleet_enroll_deadline refused a legitimate 24"
    # The same swallow existed in the soak's own date helper, where falling
    # through to the input unchanged made the window read as ALREADY CLOSED —
    # i.e. no soak, the one direction it must never fail in.
    ! fleet_trust_iso_plus_hours 2026-08-07T09:00:00Z 8h >/dev/null 2>&1 ||
      fail "fleet_trust_iso_plus_hours accepted a non-numeric hour count"
    [ "$(fleet_trust_iso_plus_hours 2026-08-07T09:00:00Z 24)" = \
      2026-08-08T09:00:00Z ] ||
      fail "fleet_trust_iso_plus_hours did not add 24 hours"

    # --- §5.1.3 the hook trust gate ---
    # The gate reads the desired `hooks:` map and definitions.yaml through the
    # ordinary fold — the same two documents §5.1.3 names, and nothing else.
    cat >"$guard_store/definitions.yaml" <<'YAML'
hooks:
  commit-guard:
    source: github:claire/commit-guard
YAML
    guard_defs=$(fleet_definitions_load "$guard_store")

    # 1. A STANDALONE hook is never trusted. Not "not yet": there is no
    #    allowlist, no flag and no install path for one anywhere in the system.
    guard_status=0
    guard_out=$(fleet_hook_trust "$guard_store" vireo "$guard_defs" commit-guard) ||
      guard_status=$?
    [ "$guard_status" -eq 1 ] ||
      fail "a standalone hook was trusted by the gate"
    case $guard_out in
      'enabled_but_untrusted '*) ;;
      *) fail "the gate did not report a standalone hook as enabled_but_untrusted: $guard_out" ;;
    esac
    case $guard_out in
      *github:claire/commit-guard*) ;;
      *) fail "the untrusted report did not name the source it refused: $guard_out" ;;
    esac

    # 2. A plugin-delivered hook whose plugin this host has NOT approved is
    #    untrusted too. The plugin trust flow is the hook trust flow (§5.1.3),
    #    so an unapproved plugin cannot smuggle a hook in behind it.
    guard_status=0
    guard_out=$(fleet_hook_trust "$guard_store" vireo "$guard_defs" \
      ponytail/session-start) || guard_status=$?
    [ "$guard_status" -eq 1 ] ||
      fail "a hook rode a plugin this host never approved"
    case $guard_out in
      *plugins.ponytail*) ;;
      *) fail "the refusal did not name the plugin whose approval is missing: $guard_out" ;;
    esac

    # 3. Approving the plugin approves its hooks — and "approval this host
    #    holds" is applied/<host>.yaml, which an item reaches only by passing
    #    this host's own review, canary and apply gates.
    fleet_applied_record "$guard_store" vireo plugins.ponytail sha-ponytail \
      "$(fleet_now)"
    guard_out=$(fleet_hook_trust "$guard_store" vireo "$guard_defs" \
      ponytail/session-start) ||
      fail "a hook whose plugin is applied on this host was still refused"
    case $guard_out in
      'trusted '*) ;;
      *) fail "the gate did not report the trusted hook as trusted: $guard_out" ;;
    esac

    # 4. THE PROPERTY, and it is the one that made `hooks` a held category
    #    until the gate existed: no apply path installs a standalone hook, not
    #    even transiently. Asserted two ways, because either alone is weak —
    #    the behaviour, and the SHAPE of the code that produces it.
    for guard_hook in commit-guard ponytail/session-start unknown-hook; do
      guard_status=0
      fleet_run_apply_item "$guard_store" vireo "$guard_defs" \
        "hooks.$guard_hook" '"enabled"' '' >/dev/null 2>&1 || guard_status=$?
      case $guard_hook in
        ponytail/session-start)
          [ "$guard_status" -eq 0 ] ||
            fail "a trusted plugin-delivered hook was refused (got $guard_status)"
          ;;
        *)
          [ "$guard_status" -eq 75 ] ||
            fail "hooks.$guard_hook was not held by the apply path (got $guard_status)"
          ;;
      esac
    done
    # The apply path's `hooks)` arm calls the gate and then RETURNS. There is
    # no clone, no install and no settings write to guard in the first place,
    # which is what makes the transient window structurally absent rather than
    # closed by the order of two statements.
    guard_arm=$(cli_function_body fleet_run_apply_item |
      sed -n '/^    hooks)$/,/^      ;;$/p')
    [ -n "$guard_arm" ] ||
      fail "the apply path has no hooks arm to inspect"
    printf '%s\n' "$guard_arm" | grep -q 'fleet_hook_trust' ||
      fail "the apply path's hooks arm does not consult the trust gate"
    ! printf '%s\n' "$guard_arm" | grep -v '^ *#' |
      grep -qE 'git clone|claude plugin|safe_output|fleet_install_package|>"' ||
      fail "the apply path's hooks arm installs something; a standalone hook must have no install path at all"
    # And the category-held predicate is genuinely off, so the refusal above
    # comes from the gate rather than from the blanket hold it replaced.
    ! fleet_category_held hooks ||
      fail "hooks is still held as a category; the per-item gate is not what refused"

    # --- §10.4 the redaction floor, over the two surfaces the sweep adds ---
    # The predicate is carried verbatim; what phase 10 adds is running it over
    # commit DESCRIPTIONS and capping replicated free text. Both halves are
    # asserted on the predicate here and over a real range in tests/94.
    fleet_quote_is_secret 'roundhouse-intent: rotate ghp_0123456789abcdefghij' ||
      fail "the sweep predicate missed a token quoted into an intent trailer"
    ! fleet_quote_is_secret 'roundhouse-intent: fast convergence' ||
      fail "the sweep predicate fired on an ordinary intent trailer"
    # --- the floor's charset/line-orientation gaps, all in one predicate ---
    # A token SPLIT ACROSS A NEWLINE evaded every per-line grep; the predicate
    # now normalizes newlines (and strips NUL) so it is seen whole.
    fleet_quote_is_secret "$(printf 'lead\neyJhbGciOiJIUzI1.eyJzdWIiOiIx.SflKxwRJ')" ||
      fail "a JWT split across a newline slipped past the sweep predicate"
    # (NUL is stripped by the shell before any argument or `read` reaches the
    # predicate, so it cannot be exercised through a fixture; the `tr -d '\000'`
    # in the predicate is defensive for a future pipe-fed caller.)
    # SINGLE-CASE / lowercase-hex high entropy is a secret too — the old
    # all-three-classes requirement made a hex key invisible.
    fleet_quote_is_secret 'abcdef0123456789abcdef0123456789abcd' ||
      fail "a 36-char lowercase-hex token was not flagged as high-entropy"
    fleet_quote_is_secret 'DEADBEEF0123456789DEADBEEF0123456789' ||
      fail "a single-case uppercase-hex token was not flagged"
    # `ghr_` is a real GitHub token prefix and was missing from the alternation.
    fleet_quote_is_secret 'token ghr_ABCdef1234567890abcdef' ||
      fail "a ghr_ GitHub token prefix was not recognised"
    # …and dropping `/` from the entropy class stops a UUID-shaped STORE PATH
    # from false-positiving: split on `/`, no segment reaches 32 chars, and a jj
    # change id (letters only, no digit) is not high-entropy either.
    ! fleet_quote_is_secret 'store.run/roster.7f3a2c9e1b04d55a' ||
      fail "a UUID-shaped store path false-positived as a secret"
    ! fleet_quote_is_secret 'kxrntvmqzuwstrpqwxrwprquoloswvxymn' ||
      fail "a jj change id (single-case letters, no digit) false-positived"
    # --- the ONE exemption is PROVED, never inferred from shape (§10.4) ---
    # The heuristic used to flag a bare git commit id as single-case hex
    # high-entropy and refuse the guarded publish — and `fleet-checkpoint`'s own
    # description quotes one. But a 40-character lowercase-hex credential and a
    # commit id are the same STRING SHAPE, so a length test would publish the
    # credential. The exemption therefore asks the repository whether the token
    # names a commit it already contains; the resolving case is exercised
    # against a real store in tests/94-jj-doctor.sh. Here: the shape predicate,
    # and the default with no store — which is NO exemption.
    #
    # `fleet_record_quote_ok`'s free text (findings/, holds) has no repository
    # context, so nothing a human types there is ever exempt.
    ! fleet_quote_is_content_address 8e765ed0c1b24a97ff3d6e5a0b1c2d3e4f506172 ||
      fail "a 40-hex token was called a content address with no store to prove it"
    ! fleet_quote_is_content_address 8e765ed0c1b24a97ff3d6e5a0b1c2d3e4f506172 \
      "$guard_root/no-such-store" ||
      fail "a token resolved as a content address against a store that does not exist"
    for guard_notaddr in '' 0123456789abcdef0123456789abcdef \
      9f2c1a4b7e0d3856af91cc42b7e5d80613a4f29cbd75e01834a6c9b2df75e013 \
      8E765ED0C1B24A97FF3D6E5A0B1C2D3E4F506172 \
      8e765ed0c1b24a97ff3d6e5a0b1c2d3e4f506172ff \
      8e765ed0c1b24a97ff3d6e5a0b1c2d3e4f5061_z; do
      ! fleet_quote_is_content_address "$guard_notaddr" "$guard_store" ||
        fail "the content-address predicate accepted a non-commit-id: '$guard_notaddr'"
    done
    # With no store, a commit-id-shaped token in free text is still a match —
    # the strictest answer, and the one the sweep's own call site upgrades by
    # passing its store.
    fleet_quote_is_secret \
      'checkpoint 3 through 8e765ed0c1b24a97ff3d6e5a0b1c2d3e4f506172' ||
      fail "free text with no repository context got an exemption anyway"
    # EVERY candidate token has to be accounted for: one the store cannot
    # explain is a secret however many commit ids sit beside it.
    cli_function_body fleet_quote_is_secret |
      grep -q 'fleet_quote_is_content_address "$quote_token" "${2:-}" || return 0' ||
      fail "the sweep predicate no longer requires every high-entropy token to be accounted for"
    # And every named class still refuses, which is what the exemption must
    # not have cost.
    fleet_quote_is_secret 'rotate ghp_0123456789abcdefghij' ||
      fail "a GitHub token stopped being refused"
    fleet_quote_is_secret '-----BEGIN OPENSSH PRIVATE KEY-----' ||
      fail "a PEM header stopped being refused"
    fleet_quote_is_secret '0123456789abcdef0123456789abcdef' ||
      fail "a 32-hex token stopped being flagged"
    fleet_quote_is_secret '9f2c1a4b7e0d3856af91cc42b7e5d80613a4f29cbd75e01834a6c9b2df75e013' ||
      fail "a 64-hex token stopped being flagged; only a proved commit id is exempt"
    # A hyphenated UUID in a path or remote URL is not a secret: `-` is out of
    # the entropy class, so it splits into its short segments.
    ! fleet_quote_is_secret 'move the store remote to /tmp/store-bf513ef6-0107-492a-ba74-f4a72b1b4fb4.git' ||
      fail "a hyphenated UUID in a remote URL false-positived as a secret"

    # --- enrollment ergonomics: identity vs transport, and the remote CLI ---
    # G2. A machine's ROSTER IDENTITY and its TRANSPORT ADDRESS are two facts,
    # and `fleet-add mac-mini` used the argument as both — so a machine whose
    # ssh alias is `claires-mac-mini` did not connect until somebody hand-added
    # a `Host mac-mini` block. The roster keeps the config machine name; only
    # the transport follows the alias.
    cat >"$tmp/guards-config.json" <<'JSONC'
{"version":1,"machines":{
  "mac-mini":{"platform":"macos","transport":"ssh","ssh_alias":"claires-mac-mini",
    "groups":[],"package_managers":[]},
  "hostile":{"platform":"linux","transport":"ssh","ssh_alias":"-oProxyCommand=curl|sh",
    "groups":[],"package_managers":[]}}}
JSONC
    [ "$(ROUNDHOUSE_CONFIG="$tmp/guards-config.json" \
      fleet_ssh_destination mac-mini)" = claires-mac-mini ] ||
      fail "the ssh destination did not resolve through the machine's configured alias"
    # An unlisted machine falls back to its own name rather than refusing: a
    # scratch host or a fixture must keep working.
    [ "$(ROUNDHOUSE_CONFIG="$tmp/guards-config.json" \
      fleet_ssh_destination scratch-box)" = scratch-box ] ||
      fail "an unlisted machine did not fall back to its own name"
    [ "$(ROUNDHOUSE_CONFIG="$tmp/missing-config.json" \
      fleet_ssh_destination mac-mini)" = mac-mini ] ||
      fail "an unreadable config did not fall back to the name"
    # The alias comes out of a file this code did not write and reaches ssh as
    # argv, so it passes the SAME allowlist every other destination passes: an
    # option-shaped alias is refused here, never turned into an ssh flag.
    ! ROUNDHOUSE_CONFIG="$tmp/guards-config.json" \
      fleet_ssh_destination hostile >/dev/null 2>&1 ||
      fail "an option-shaped ssh_alias reached the transport"

    # G1. The plugin ships no `roundhouse` on anybody's PATH — skills invoke it
    # through its relative scripts/roundhouse — so `fleet-add`'s bare remote
    # `roundhouse fleet-init` did nothing on every host that had no hand-written
    # shim, and the `|| :` made that indistinguishable from success. The
    # prologue RESOLVES the CLI on the far side instead of assuming it.
    guard_prologue=$(fleet_remote_cli_prologue)
    case $guard_prologue in
      *'command -v roundhouse'*) ;;
      *) fail "the remote prologue does not prefer a launcher already on PATH" ;;
    esac
    # THE SPONSOR'S OWN VERSION IS TRIED FIRST, by exact path: falling straight
    # to "whichever cached copy sorts last" drives bytes this host did not
    # choose, and lexically last is not even newest (0.9.0 sorts after 0.10.0),
    # so it could be an arbitrarily old build whose gates this one has added.
    guard_version=$(jq -r '.version' \
      "$(dirname -- "$cli")/../.codex-plugin/plugin.json")
    case $guard_prologue in
      *"/roundhouse/$guard_version/scripts/roundhouse"*) ;;
      *) fail "the remote prologue does not ask for the sponsor's own version first: $guard_version" ;;
    esac
    printf '%s\n' "$guard_prologue" >"$tmp/guards-prologue.sh"
    assert_ordered "$tmp/guards-prologue.sh" \
      "/roundhouse/$guard_version/scripts/roundhouse" \
      '/roundhouse/*/scripts/roundhouse'
    for guard_cache in .claude/plugins/cache .codex/plugins/cache; do
      case $guard_prologue in
        *"$guard_cache"*) ;;
        *) fail "the remote prologue cannot find the CLI under ~/$guard_cache" ;;
      esac
    done
    # POSIX sh on the far side: no `local`, no bash arrays, no `[[`.
    ! printf '%s\n' "$guard_prologue" | grep -qE '(^|[^A-Za-z])(local |\[\[)' ||
      fail "the remote prologue uses a bashism; it runs under the peer's /bin/sh"
    printf '%s\n' "$guard_prologue" | sh -n ||
      fail "the remote prologue is not valid POSIX sh"
    # It FAILS LOUD rather than falling through to a bare command name.
    case $guard_prologue in
      *'exit 69'*) ;;
      *) fail "the remote prologue does not refuse when it finds no CLI" ;;
    esac
    guard_status=0
    (
      # An empty HOME (no plugin cache) and a PATH with no roundhouse on it —
      # /usr/bin:/bin so `sh` itself still resolves, which is what the prologue
      # runs under on the peer.
      HOME=$tmp/guards-empty-home
      mkdir -p "$HOME"
      PATH=/usr/bin:/bin
      export HOME PATH
      printf '%s\n' "$guard_prologue" | sh
    ) >/dev/null 2>&1 || guard_status=$?
    [ "$guard_status" -eq 69 ] ||
      fail "the remote prologue did not exit 69 on a host with no CLI (got $guard_status)"

    # U2. §10.6's probe, as ONE function both the verb and `fleet-add` call.
    # A FAILED PROBE IS NOT EVIDENCE OF PRIVACY: only an authentication refusal
    # proves the remote is gated.
    [ "$(ROUNDHOUSE_SELFTEST=1 \
      ROUNDHOUSE_FLEET_VISIBILITY_PROBE='printf "Permission denied (publickey)\n" >&2; exit 128' \
      fleet_remote_visibility_probe https://example.invalid/store.git)" = \
      'true auth-required' ] ||
      fail "an authentication refusal was not read as a private remote"
    [ "$(ROUNDHOUSE_SELFTEST=1 ROUNDHOUSE_FLEET_VISIBILITY_PROBE='exit 0' \
      fleet_remote_visibility_probe https://example.invalid/store.git)" = \
      'false public' ] ||
      fail "a remote that answered unauthenticated reads was not read as public"
    [ "$(ROUNDHOUSE_SELFTEST=1 \
      ROUNDHOUSE_FLEET_VISIBILITY_PROBE='printf "could not resolve host\n" >&2; exit 128' \
      fleet_remote_visibility_probe https://example.invalid/store.git)" = \
      'false probe-inconclusive' ] ||
      fail "an unreachable remote was treated as evidence of privacy"
    # It ALWAYS prints a verdict, so no caller can be handed an empty one: a
    # tempdir it cannot allocate is the "could not measure" case
    # `probe-inconclusive` already exists for, and that never satisfies the
    # first-push gate. Silence here would put an empty reason in posture.yaml
    # and a blank explanation in fleet-add's refusal.
    [ "$(TMPDIR="$tmp/guards-no-such-tmpdir" ROUNDHOUSE_SELFTEST=1 \
      ROUNDHOUSE_FLEET_VISIBILITY_PROBE='exit 0' \
      fleet_remote_visibility_probe https://example.invalid/store.git \
      2>/dev/null)" = 'false probe-inconclusive' ] ||
      fail "the probe produced no verdict when it could not allocate a tempdir"
    # …and `fleet-add` consumes it as a REFUSAL that records nothing. The
    # verdict is read before any roster write, so a public remote never
    # acquires a roster line naming a new machine.
    cli_function_body fleet_add_command >"$tmp/guards-add.sh"
    grep -q 'fleet_remote_visibility_probe' "$tmp/guards-add.sh" ||
      fail "fleet-add does not establish the remote's posture at enrollment (§10.6 stays one manual step per host)"
    assert_ordered "$tmp/guards-add.sh" 'fleet_remote_visibility_probe' \
      'fleet_enroll_roster_touch'
    # The roster identity stays the config machine name; only the transport
    # follows the alias, so every host-keyed path and signature still checks
    # against the name the instruction gave.
    grep -q 'add_ssh=$(fleet_ssh_destination "$add_target")' "$tmp/guards-add.sh" ||
      fail "fleet-add does not resolve its transport separately from the roster identity"
    ! grep -q 'ssh_run "\$add_target"' "$tmp/guards-add.sh" ||
      fail "fleet-add still uses the roster name as an ssh destination"

    # --- §7.3a the host-name allowlist, the sink joins/<h>.yaml reaches ---
    # A joins/ file is written by a NON-MEMBER, and its `.address` (and file
    # name) reach `ssh_run` as a destination argv (fleet_enroll_process_joins).
    # fleet_host_name_ok is the one predicate that gates it: a leading `-`
    # becomes an ssh OPTION (`-oProxyCommand=…`), a metacharacter is shell
    # injection, and `.`/`..`/empty are the path-escape names — all refused,
    # only a real host/IP shape accepted.
    for guard_badhost in '-oProxyCommand=curl|sh' '-oProxyCommand' \
        'a;rm -rf x' 'a b' 'a|b' 'a$(x)' 'a/../b' '' . ..; do
      ! fleet_host_name_ok "$guard_badhost" ||
        fail "fleet_host_name_ok accepted a host that reaches ssh argv: [$guard_badhost]"
    done
    for guard_goodhost in vireo vireo.local iris-wsl 192.168.1.5 mac_studio; do
      fleet_host_name_ok "$guard_goodhost" ||
        fail "fleet_host_name_ok refused a legitimate host/IP: [$guard_goodhost]"
    done

    guard_long=$(awk 'BEGIN { while (n++ < 401) printf "x" }')
    [ "$(printf '%s' "$guard_long" | wc -c | tr -d ' ')" -eq 401 ] ||
      fail "the over-cap fixture is not over the cap"
    ! fleet_replicated_text_ok "$guard_long" 2>/dev/null ||
      fail "a 401-byte replicated field passed the 400-byte cap"
    fleet_replicated_text_ok "${guard_long%x}" 2>/dev/null ||
      fail "a field exactly at the cap was refused"

    # --- §8.2/§8.4 the fail-CLOSED guards on the paths that leave this machine ---
    # These are the sites where a swallowed exit turned a failure into a false
    # success. Asserted at the source, the way the private-remote gate's banned
    # git calls are below: a guard that regresses is a guard that reads clean.
    guard_pub=$(cli_function_body fleet_vcs_publish)
    # The push captures its rejection so it can tell a CONCURRENT REMOTE MOVE
    # (recover: fetch, reconcile, re-publish once) from a GENUINE failure (fail
    # closed, propagate the rc). A failed push must never be dressed as success.
    printf '%s\n' "$guard_pub" | grep -qE 'git push --bookmark main.*2>&1' ||
      fail "the push does not capture its rejection to classify move-vs-failure"
    printf '%s\n' "$guard_pub" | grep -q "'stale info'" ||
      fail "the publish recovery is not gated on the concurrent-move signal (would recover on genuine errors)"
    printf '%s\n' "$guard_pub" | grep -q 'no-recover' ||
      fail "the publish recovery has no one-shot guard against re-entering itself"
    printf '%s\n' "$guard_pub" | grep -q 'return "\$fleet_vcs_pushrc"' ||
      fail "a genuine push failure does not propagate its exit (fail closed)"
    printf '%s\n' "$(cli_function_body fleet_vcs_git_conflict_paths)" |
      grep -q 'ls-tree.*|| return' ||
      fail "the inbound-conflict detector does not fail closed on a git error"
    ! printf '%s\n' "$(cli_function_body fleet_run_command)" |
      grep -F 'fleet_trust_materialize "$run_store" "$run_reference"' |
      grep -q '|| :' ||
      fail "a materialize refusal is still swallowed with || : (§7.12.3 never holds)"
    # §7.11.2 catch-up threads the reviewed roster into the archived-chain replay
    # so rule 4 ("removals bite backward") is not skipped there.
    printf '%s\n' "$(cli_function_body fleet_trust_catch_up)" |
      grep -q 'reviewed-for-replay' ||
      fail "the catch-up replay does not thread a reviewed roster (rule 4 skipped)"
    # §10.4 the sweep captures its enumeration exit rather than piping `jj log`
    # straight into `while`, so a failed enumeration is not read as swept clean.
    printf '%s\n' "$(cli_function_body fleet_sweep_range)" |
      grep -q 'sweep_rc' ||
      fail "the redaction sweep does not capture the enumeration exit (empty range = clean)"
    # §7.12.3 materialize tolerates LOCAL unpublished work: a sweep-refused or
    # conflicted run advances reviewed-ref to a head it never pushed, and the
    # §10.4 recovery (abandon / op restore + reset to main@origin) then leaves
    # the next head a sibling of reviewed-ref. That is a local rewrite, not the
    # rollback attack (a DIVERGENT origin), so the check is keyed on whether
    # reviewed-ref descends from main@origin — refuse only when it does not.
    printf '%s\n' "$(cli_function_body fleet_trust_materialize)" |
      grep -q 'present(main@origin) & ::' ||
      fail "materialize's §7.12.3 check has no local-supersede tolerance; the documented recovery would brick every future materialize"

    # --- §10.6 the private-remote posture, host-local by construction ---
    case $(fleet_posture_path) in
      "$guard_root"/store.local/posture.yaml) ;;
      *) fail "posture.yaml is not host-local under the instance root: $(fleet_posture_path)" ;;
    esac
    [ -z "$(fleet_posture_get remote_visibility_verified)" ] ||
      fail "an absent posture file did not read as unverified"
    fleet_record_write "$(fleet_posture_path)" \
      '{"remote_visibility_verified":true,"remote_visibility_reason":"auth-required"}'
    [ "$(fleet_posture_get remote_visibility_verified)" = true ] ||
      fail "posture.yaml did not read back the verified flag"
    ! grep -q 'schema' "$(fleet_posture_path)" ||
      fail "the posture record carries a banned schema key"
    # The gate's reads are jj-native. §8.4 admits exactly two read-only git
    # calls and neither is `git remote get-url` or `git show-ref`; the v1 gate
    # used both, and the review record caught that the rule had been applied to
    # the symlink row and not to this one.
    guard_gate=$( (cli_function_body fleet_first_push_gate
      cli_function_body fleet_remote_url) | grep -v '^ *#')
    ! printf '%s\n' "$guard_gate" | grep -qE 'git remote get-url|git show-ref' ||
      fail "the private-remote gate still reads through banned git calls"
    printf '%s\n' "$guard_gate" | grep -q 'jj -R "\$1" git remote list' ||
      fail "the private-remote gate does not read the remote through jj"

    # --- §10.6 the stale-lock threshold, re-based on the FULL cadence ---
    # Two full cadences, and never anything derived from the fast interval: a
    # 20-minute fast interval through the same expression gives a ~40-minute
    # threshold, which declares a LIVE full run's lock stale on the next fast
    # run and is how every later run gets stuck.
    printf 'policy:\n  cadence_hours: 6\n  fast_interval_minutes: 20\n' \
      >"$guard_store/fleet.yaml"
    printf 'platform: macos\n' >"$guard_store/hosts/vireo.yaml"
    [ "$(fleet_run_stale_after "$guard_store" vireo)" -eq $((6 * 7200)) ] ||
      fail "the stale-lock threshold is not two full cadences: $(fleet_run_stale_after "$guard_store" vireo)"
    printf 'policy:\n  cadence_hours: 12\n  fast_interval_minutes: 1\n' \
      >"$guard_store/fleet.yaml"
    [ "$(fleet_run_stale_after "$guard_store" vireo)" -eq $((12 * 7200)) ] ||
      fail "the stale-lock threshold moved with the fast interval"
    guard_stale=$(cli_function_body fleet_run_stale_after)
    ! printf '%s\n' "$guard_stale" | grep -v '^ *#' | grep -q fast_interval ||
      fail "the stale-lock threshold reads the fast interval"
    # A store with no policy at all still gets the design's own cadence rather
    # than a zero threshold, which would call every lock stale immediately.
    [ "$(fleet_run_stale_after "$guard_root/nothing-here" vireo)" -eq $((12 * 7200)) ] ||
      fail "a store with no policy produced no stale-lock threshold"
    # A NON-INTEGER policy value must not CRASH the arithmetic. A signed
    # `cadence_hours: 12.0` reached bare `$(( … ))` and exited bash with an
    # undocumented error, no alert, on every host; the value is floored (or the
    # default is used) and the run keeps going, never `$(( 12.0 * 7200 ))`.
    printf 'policy:\n  cadence_hours: 12.0\n' >"$guard_store/fleet.yaml"
    guard_float_rc=0
    guard_float=$(fleet_run_stale_after "$guard_store" vireo) || guard_float_rc=$?
    [ "$guard_float_rc" -eq 0 ] ||
      fail "a float cadence_hours crashed the stale-lock arithmetic (exit $guard_float_rc)"
    [ "$guard_float" -eq $((12 * 7200)) ] ||
      fail "a float cadence_hours did not floor to the integer threshold: $guard_float"
    printf 'policy:\n  cadence_hours: not-a-number\n  fast_interval_minutes: 3.5\n' \
      >"$guard_store/fleet.yaml"
    guard_float_rc=0
    guard_float=$(fleet_run_interval_seconds \
      "$(fleet_fold "$guard_store" vireo)" vireo fast) || guard_float_rc=$?
    [ "$guard_float_rc" -eq 0 ] ||
      fail "a non-numeric policy crashed the interval arithmetic (exit $guard_float_rc)"

    # --- §10.6 sync-adopt-pin: the containment carries, the record does not ---
    guard_pin="$guard_root/pin.json"
    jq -n '{sha:"sha-rh-2", version:"9.9.9", updated_by:"wren"}' >"$guard_pin"
    # roundhouse updating itself is gated on a peer already carrying the pin.
    guard_status=0
    guard_out=$("$cli" fleet-adopt-pin roundhouse "$guard_pin") || guard_status=$?
    [ "$guard_status" -eq 65 ] ||
      fail "roundhouse adopted its own pin with no evidence any host is carrying it"
    [ "$(printf '%s\n' "$guard_out" | jq -r '.adopted')" = false ] ||
      fail "the refusal record does not say it refused"
    # Every other plugin rides the ordinary gates; a second gate in front of
    # them would be a second policy to keep in step with the first.
    "$cli" fleet-adopt-pin ponytail "$guard_pin" >/dev/null ||
      fail "an ordinary plugin was contained like roundhouse"
    # The evidence is applied/<updating-host>.yaml, and §7.3 says only that
    # host could have written it.
    fleet_applied_record "$guard_store" wren plugins.roundhouse sha-rh-2 "$(fleet_now)"
    guard_out=$("$cli" fleet-adopt-pin roundhouse "$guard_pin") ||
      fail "roundhouse refused a pin a peer has applied"
    [ "$(printf '%s\n' "$guard_out" | jq -r '.adopted')" = true ] ||
      fail "the adopt record does not say it adopted"
    # §14: the record is an ordinary item under the closed category set. v1
    # wrote schema:"roundhouse.sync-adopt-pin" and schema_version:1 here.
    [ "$(printf '%s\n' "$guard_out" | jq -r '.item')" = plugins.roundhouse ] ||
      fail "the adopt-pin record is not an ordinary item id"
    [ "$(printf '%s\n' "$guard_out" |
      jq -r 'has("schema") or has("schema_version")')" = false ] ||
      fail "the adopt-pin record still carries a banned schema key"

    # --- §14 the sweep the review record asked for, grep-wide over lib/ ---
    # Not row by row: the stale-lock refusal record carried the same two keys
    # and its §10.6 row mentioned only the threshold.
    # shellcheck disable=SC2046 # deliberate word splitting over the file list
    ! grep -nE '"?schema(_version)?"? *:' $(cli_program_files) |
      grep -vE ':[0-9]+: *#' |
      grep -vE 'roundhouse\.inventory|schema=|integrity|plan-|apply-commands|broker-|identity\.sh|inventory\.sh|host\.sh|config\.sh' |
      grep -q . ||
      fail "a DSC record still emits schema: or schema_version:"
  ) || fail "guards fixture block failed"
fi
