# roundhouse — fleet store primitives: host-local paths, identity, the run
# environment, the store id, and the shared predicates.
#
# The v1 store (four scattered layers, a `host/<name>` branch, git-based
# signing, absorb/render/materialize/lease) is deleted; the replacement is
# specified in `docs/specs/2026-08-06-dsc-storage-design-v2.md`. What survived
# that deletion lives here alongside what the ratchet needs: predicates and
# resolvers that cost a review round to get right.
#
# Sourced by scripts/roundhouse; carries definitions only.
# shellcheck shell=bash

fleet_test_hook() {
  # Test-only hooks (visibility probe, approval command, relocated trust
  # roots) are inert unless the self-check explicitly turns them on: a stray
  # environment variable must never disable a safety gate on a real host.
  [ "${ROUNDHOUSE_SELFTEST:-0}" = 1 ] || return 1
  [ -n "${1:-}" ]
}

fleet_allowed_signers_path() {
  # Host-local by doctrine: never a path inside the store, and never read live
  # from the working copy — the file being verified would supply its own
  # verification keys. `trustd` re-derives it from the store's own verified
  # history (§7.9), and $TRUST decides where it lands.
  printf '%s/allowed_signers\n' "$(fleet_trust_root)"
}

fleet_signer_entry() {
  # keytype + base64 only. The trailing comment in a .pub file is free text and
  # must never reach a signers entry, where it would be parsed as a principal.
  awk 'NF >= 2 && $1 ~ /^(ssh-|ecdsa-|sk-)/ { printf "%s %s\n", $1, $2; exit }' "$1"
}

fleet_store_path() {
  # One resolver, and the only one: no later phase writes a store path
  # literal. The v2 design's second instance root (the Windows/WSL sibling)
  # hangs off this function, not off a second copy of it.
  if [ -n "${ROUNDHOUSE_FLEET_STORE:-}" ]; then
    printf '%s\n' "$ROUNDHOUSE_FLEET_STORE"
    return
  fi
  printf '%s/roundhouse/store\n' "${XDG_CONFIG_HOME:-"$HOME/.config"}"
}

fleet_instance_root() {
  # §2's host-local root: identity.yaml, local.yaml, allowed_signers, krl,
  # store/, store.run/, store.local/. Derived from the ONE store resolver
  # above rather than resolved a second way, which is what makes R5's second
  # instance (the Windows sibling under ~/.config/roundhouse-iris-windows/)
  # genuinely the same code run twice: point ROUNDHOUSE_FLEET_STORE at the
  # second store and every host-local file follows it.
  #
  # R5 NOTE, held open through phase 10 and settled here: the seam is TWO
  # INSTANCES, ONE PROCESS AT A TIME — two roots, two identities, two stores,
  # two run-locks, and nothing that runs them concurrently in one process.
  # Every command resolves its paths from the environment at entry, so a
  # caller that wants both drives the CLI twice with a different
  # ROUNDHOUSE_FLEET_STORE. Nothing in CI can exercise the real pairing (it is
  # a Windows host and its WSL sibling); what tests/90-jj-bootstrap.sh proves
  # is the property that makes it work — two store paths give two disjoint
  # host-local roots. Making one process hold both would mean re-entrant path
  # state in every unit, and there is no caller asking for it.
  dirname "$(fleet_store_path)"
}

fleet_instance_path() {
  # The only way to name a host-local file. `fleet_instance_path store.run`,
  # `… store.local`, `… local.yaml` — no unit writes the root itself.
  printf '%s/%s\n' "$(fleet_instance_root)" "$1"
}

fleet_identity_path() {
  fleet_instance_path identity.yaml
}

fleet_identity_get() {
  # One scalar out of host-local identity.yaml, or nothing. Absent file and
  # absent key are the same answer on purpose: every caller has to handle
  # "not stated" anyway, and a host between `jj git clone` and `fleet-init`
  # legitimately has neither.
  identity_file=$(fleet_identity_path)
  [ -f "$identity_file" ] || return 0
  FLEET_IDENTITY_KEY=$1 yq -r '.[strenv(FLEET_IDENTITY_KEY)] // ""' \
    "$identity_file" 2>/dev/null || true
}

fleet_identity_set() {
  # `fleet_identity_set KEY VALUE` — set one scalar in host-local identity.yaml,
  # preserving every other key (and comments). Used to back-fill the founder's
  # own `store_id` after genesis (§7.5): every other host is pinned by its
  # sponsor, and the founding host must end pinned to its own genesis too — a
  # host that never pins reaches roster_derive's genesis self-verify branch for
  # ANY parentless commit.
  identity_file=$(fleet_identity_path)
  mkdir -p "$(dirname "$identity_file")"
  [ -f "$identity_file" ] || : >"$identity_file"
  FLEET_IDENTITY_KEY=$1 FLEET_IDENTITY_VALUE=$2 \
    yq -i '.[strenv(FLEET_IDENTITY_KEY)] = strenv(FLEET_IDENTITY_VALUE)' \
    "$identity_file"
}

fleet_signing_key_path() {
  # This machine's own node key. There is no certificate beside it and no
  # authority that issued it: peers hold the roster, which lists this key by
  # value. §3.3 mints it at fleet-enroll with `ssh-keygen -t ed25519 -N ''`.
  if [ -n "${ROUNDHOUSE_FLEET_SIGNING_KEY:-}" ]; then
    printf '%s\n' "$ROUNDHOUSE_FLEET_SIGNING_KEY"
    return
  fi
  printf '%s/.ssh/roundhouse_node_ed25519\n' "$HOME"
}

fleet_fleet_domain() {
  # §7.1's identity namespace, DERIVED rather than configured, in order:
  # the owner's own domain when it is not freemail, then
  # `<github-username>.fleet.internal` (gh is already a prerequisite and
  # `.internal` is ICANN-reserved for exactly this), then `fleet.internal`.
  #
  # Non-unique defaults are safe, and that is a property of the RATCHET rather
  # than of the name: two unrelated fleets both landing on `fleet.internal`
  # cannot touch each other, because trust anchors to this fleet's roster —
  # which lists specific keys — and to the genesis pin. A principal string is a
  # label for a key that is either in your roster or is not; it is never itself
  # an authorization. So no uniqueness ceremony, registry or collision check
  # exists anywhere.
  domain_stated=$(fleet_identity_get domain)
  [ -z "$domain_stated" ] || {
    printf '%s\n' "$domain_stated"
    return
  }
  domain_email=$(git config user.email 2>/dev/null || true)
  domain_part=${domain_email#*@}
  case $domain_email in
    *@*)
      case $domain_part in
        gmail.com | googlemail.com | outlook.com | hotmail.com | live.com | \
          yahoo.com | icloud.com | me.com | proton.me | protonmail.com | aol.com) ;;
        *)
          printf 'fleet.%s\n' "$domain_part"
          return
          ;;
      esac
      ;;
  esac
  domain_gh=$(gh api user --jq '.login' 2>/dev/null || true)
  case $domain_gh in
    '' | *[!A-Za-z0-9-]*) printf 'fleet.internal\n' ;;
    *) printf '%s.fleet.internal\n' "$(printf '%s' "$domain_gh" | tr 'A-Z' 'a-z')" ;;
  esac
}

fleet_principal() {
  # `<node_id>@<domain>` — this host's roster principal, and also the store's
  # committer identity, which is what makes §7.3's equality gate meaningful.
  principal_stated=$(fleet_identity_get principal)
  [ -z "$principal_stated" ] || {
    printf '%s\n' "$principal_stated"
    return
  }
  printf '%s@%s\n' "$(fleet_host_name)" "$(fleet_fleet_domain)"
}

fleet_run_env() {
  # §3.2, the hard requirement: no jj, git or ssh-keygen invocation this
  # system makes may be capable of falling through to an editor, a pager, a
  # credential prompt, or any other UI. One function, sourced by every
  # command, because a run that can block on a human hangs a machine nobody
  # is sitting at.
  #
  # BatchMode=yes is the knob, not SSH_ASKPASS_REQUIRE=never: the latter only
  # suppresses the GUI askpass and a TTY passphrase prompt still happens.
  # Closed stdin covers it in practice; both are here so removing one later
  # does not silently remove the mechanism. Commands are subshell bodies, so
  # `exec` closes stdin for the command, not for the caller's shell.
  JJ_EDITOR=true
  GIT_EDITOR=true
  PAGER=cat
  GIT_TERMINAL_PROMPT=0
  GIT_SSH_COMMAND='ssh -o BatchMode=yes'
  export JJ_EDITOR GIT_EDITOR PAGER GIT_TERMINAL_PROMPT GIT_SSH_COMMAND
  exec </dev/null
}

fleet_host_name() {
  # §12's identity.yaml is the host's own name, and it is the only source that
  # survives a rename: `hostname -s` is what the machine calls itself and
  # `config.json` is the privilege lane's table (declared boundary B-1). A
  # second instance on one machine (the Windows/WSL sibling, R5) is two
  # identity files, which is why this is read before either fallback.
  identity_name=$(fleet_identity_get name)
  [ -z "$identity_name" ] || {
    printf '%s\n' "$identity_name"
    return
  }
  configured=$(jq -r \
    '[.machines | to_entries[] | select(.value.transport == "local") | .key][0] // empty' \
    "$(config_path)" 2>/dev/null || true)
  if [ -n "$configured" ]; then
    printf '%s\n' "$configured"
  else
    hostname -s
  fi
}

fleet_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

fleet_lock_path() {
  printf '%s.lock\n' "$(fleet_store_path)"
}

fleet_lock_nonce() {
  # 128 random bits as hex. The nonce is what makes a lock THIS acquisition's
  # rather than whatever directory happens to sit at the path: release and
  # takeover both compare it, and neither ever acts on the path alone.
  od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n'
}

fleet_lock_proc_start() {
  # `fleet_lock_proc_start PID` — the process's start time as `ps` prints it,
  # whitespace-normalised, or nothing when no such process exists. `lstart` is
  # spelled the same by BSD (macOS) and procps (Linux) ps, and it is what tells
  # a live holder from an unrelated process that was handed the same pid.
  # Pinned to UTC and the C locale: `lstart` is printed in the READER's zone and
  # language, and a scheduled run and an interactive one need not share either
  # — a mismatch there would judge a live holder dead.
  LC_ALL=C TZ=UTC0 ps -o lstart= -p "$1" 2>/dev/null |
    awk '{ $1 = $1; if ($0 != "") print; exit }'
}

fleet_lock_proc_command() {
  # `fleet_lock_proc_command PID` — the process's full command line, or
  # nothing. Host-local evidence only: it lands in the lock meta beside the
  # store, never in a replicated record. `-ww`: procps cuts `command` to the
  # terminal width otherwise, and two reads at different widths would disagree.
  ps -ww -o command= -p "$1" 2>/dev/null |
    awk '{ sub(/[[:space:]]+$/, ""); if ($0 != "") print; exit }'
}

fleet_lock_acquire() {
  # `fleet_lock_acquire LOCK_DIR [HOLDER_PID] [manual]` — one lock shape for every entry
  # point: the directory is the mutex, the meta file is the evidence doctor and
  # the holder check read. Sets `fleet_lock_nonce_held` to this acquisition's
  # nonce, which is the only thing `fleet_lock_release` will act on.
  #
  # The meta names the holder by pid, start time AND command, because a pid
  # alone is not an identity: after a crash or reboot the same number belongs
  # to something else, and `kill -0` cannot tell the difference. HOLDER_PID
  # defaults to this process.
  #
  # `manual` marks a lock taken by hand (`fleet-lock`). Its recorded pid is the
  # caller's shell, which is often gone a second later — so a hand-taken lock
  # is never judged dead (fleet_lock_holder_state answers `unknown`) and the
  # age rule governs it exactly as before: a scheduled run must not take over
  # an operator's lock and publish their half-done edits.
  #
  # Exit 1 when the lock is held, 2 when the directory was created but its
  # evidence could not be written: a lock nobody can identify is a lock nobody
  # can safely release or take over, so it is removed rather than left behind.
  lock_dir=$1
  lock_pid=${2:-$$}
  lock_manual=false
  [ "${3:-}" != manual ] || lock_manual=true
  fleet_lock_nonce_held=
  mkdir "$lock_dir" 2>/dev/null || return 1
  chmod 0700 "$lock_dir"
  lock_nonce=$(fleet_lock_nonce)
  if [ -n "$lock_nonce" ] &&
    jq -S -n --arg host "$(fleet_host_name)" --argjson pid "$lock_pid" \
      --arg started "$(fleet_now)" --arg start_time "$(fleet_lock_proc_start "$lock_pid")" \
      --arg command "$(fleet_lock_proc_command "$lock_pid")" --arg nonce "$lock_nonce" \
      --argjson manual "$lock_manual" \
      '{host:$host,pid:$pid,started_at:$started,start_time:$start_time,
        command:$command,nonce:$nonce} + (if $manual then {manual:true} else {} end)' \
      >"$lock_dir/meta.json.tmp" 2>/dev/null &&
    mv -f "$lock_dir/meta.json.tmp" "$lock_dir/meta.json"; then
    fleet_lock_nonce_held=$lock_nonce
    return 0
  fi
  rm -rf "$lock_dir"
  return 2
}

fleet_lock_meta_field() {
  # `fleet_lock_meta_field LOCK_DIR FIELD` — one scalar from the lock's meta,
  # or nothing (no meta, unparsable meta, absent field).
  [ -f "$1/meta.json" ] || return 0
  jq -r --arg f "$2" '.[$f] // empty | tostring' "$1/meta.json" 2>/dev/null || true
}

fleet_lock_identity() {
  # `fleet_lock_identity LOCK_DIR` — what a takeover binds to: the nonce, or for
  # a lock written before nonces existed, its pid and start stamp. The legacy
  # form is what lets the first nonce-aware run recover a lock a dead pre-nonce
  # run left behind — the exact wedge this mechanism exists for — while still
  # refusing to move any lock it did not judge.
  lock_identity=$(fleet_lock_meta_field "$1" nonce)
  # LEGACY (pre-nonce locks): delete this branch one release after the nonce
  # lock ships, once no host can still hold a lock an older build wrote.
  if [ -z "$lock_identity" ]; then
    lock_identity_pid=$(fleet_lock_meta_field "$1" pid)
    lock_identity_at=$(fleet_lock_meta_field "$1" started_at)
    [ -z "$lock_identity_pid" ] || [ -z "$lock_identity_at" ] ||
      lock_identity="legacy:$lock_identity_pid:$lock_identity_at"
  fi
  printf '%s\n' "$lock_identity"
}

fleet_lock_release() {
  # `fleet_lock_release LOCK_DIR NONCE` — remove the lock ONLY when it still
  # carries this acquisition's nonce. A run that was judged dead and taken over
  # must not, when it finally exits, delete the live successor's lock by path.
  [ -n "${2:-}" ] || return 0
  [ "$(fleet_lock_meta_field "$1" nonce)" = "$2" ] || return 0
  rm -f "$1/meta.json"
  rmdir "$1" 2>/dev/null || :
}

fleet_lock_holder_state() {
  # `fleet_lock_holder_state LOCK_DIR` — sets `fleet_lock_state` to `dead`,
  # `live` or `unknown`, and `fleet_lock_judged_id` to the identity
  # (fleet_lock_identity) the verdict is about. Globals rather than output, so
  # the takeover that follows can use the identity: call it directly.
  #
  # dead     the meta names a pid on THIS host that no longer exists, or a live
  #          pid whose start time or command is not the recorded holder's (pid
  #          reuse after a crash or a reboot)
  # live     the recorded holder is running right now, verified by all three
  # unknown  nothing here can be proved either way: no readable meta, another
  #          host's pid, a hand-taken (`manual`) lock, a pre-nonce lock whose
  #          pid is alive, or no identity to bind a takeover to
  #
  # The host name is compared because the lock lives beside a store path that
  # a second instance root could share; a pid from another machine says
  # nothing about this one.
  fleet_lock_judged_id=
  fleet_lock_state=unknown
  lock_meta="$1/meta.json"
  [ -f "$lock_meta" ] || return 0
  jq -e 'type == "object"' "$lock_meta" >/dev/null 2>&1 || return 0
  [ "$(fleet_lock_meta_field "$1" host)" = "$(fleet_host_name)" ] || return 0
  # A hand-taken lock names a shell that may already have exited; its holder
  # is the operator, whom no `ps` can see. The age rule decides it.
  [ "$(fleet_lock_meta_field "$1" manual)" != true ] || return 0
  lock_pid=$(fleet_lock_meta_field "$1" pid)
  case $lock_pid in
    '' | *[!0-9]*) return 0 ;;
  esac
  # A `ps` that cannot see THIS process cannot see anything, and reading its
  # silence as "the holder is gone" would take over a live run's lock.
  [ -n "$(fleet_lock_proc_start "$$")" ] || return 0
  fleet_lock_judged_id=$(fleet_lock_identity "$1")
  lock_now_start=$(fleet_lock_proc_start "$lock_pid")
  lock_was_start=$(fleet_lock_meta_field "$1" start_time)
  lock_was_command=$(fleet_lock_meta_field "$1" command)
  if [ -z "$lock_now_start" ]; then
    fleet_lock_state=dead
  elif [ -z "$lock_was_start" ] || [ -z "$lock_was_command" ]; then
    # A lock written before holders were recorded: the pid is alive and there
    # is no evidence about whose it is, so this answer keeps the age rule.
    # LEGACY (pre-nonce locks): delete this branch one release after the
    # nonce lock ships, together with fleet_lock_identity's legacy form.
    fleet_lock_state=unknown
  elif [ "$lock_now_start" != "$lock_was_start" ] ||
    [ "$(fleet_lock_proc_command "$lock_pid")" != "$lock_was_command" ]; then
    fleet_lock_state=dead
  else
    fleet_lock_state=live
  fi
  # A dead verdict is only actionable against an identity: the takeover proves
  # it moved the SAME lock it judged, and without one there is nothing to prove.
  [ "$fleet_lock_state" != dead ] || [ -n "$fleet_lock_judged_id" ] ||
    fleet_lock_state=unknown
}

fleet_lock_takeover() {
  # `fleet_lock_takeover LOCK_DIR JUDGED_ID [HOLDER_PID]` — replace a lock
  # whose holder `fleet_lock_holder_state` judged dead, atomically:
  #
  #   1. rename the lock directory to a unique sibling (rename(2) is atomic, so
  #      of two runs racing the same dead lock exactly one moves it);
  #   2. verify the renamed directory carries the identity judged dead —
  #      if a racing run already replaced it with a live lock, this run moved
  #      THAT one, so it is put back and the takeover refused;
  #   3. create the new lock through the ordinary acquire.
  #
  # Sets `fleet_lock_dead_meta` to the dead holder's meta (compact JSON) for
  # the caller's alert, and `fleet_lock_nonce_held` through the acquire — so it
  # is called directly, never in a command substitution. Exit 1 when the
  # takeover was refused or lost a race.
  fleet_lock_dead_meta=
  [ -n "${2:-}" ] || return 1
  lock_aside="$1.dead.$(fleet_lock_nonce)"
  mv "$1" "$lock_aside" 2>/dev/null || return 1
  if [ "$(fleet_lock_identity "$lock_aside")" != "$2" ]; then
    # Never `mv` onto an existing directory: that would nest the lock inside
    # whatever now holds the path. If the path was taken meanwhile, the moved
    # lock stays aside and its owner's nonce release simply finds nothing.
    [ -e "$1" ] || mv "$lock_aside" "$1" 2>/dev/null || :
    return 1
  fi
  lock_dead_meta=$(jq -c '.' "$lock_aside/meta.json" 2>/dev/null || printf '{}')
  fleet_lock_acquire "$1" "${3:-$$}" || {
    rm -rf "$lock_aside"
    return 1
  }
  rm -rf "$lock_aside"
  fleet_lock_dead_meta=$lock_dead_meta
}

# --- §6.3 the run lock: liveness before age ------------------------------------

fleet_run_lock_take() {
  # fleet_run_lock_take STORE HOST LOCK — take the run lock for any entry point
  # that mutates this host's store. Exit 0 acquired (`fleet_lock_nonce_held`
  # names it), 10 held by a live run (the ordinary overlap; the caller decides
  # whether that is success), 75 refused.
  #
  # THE HOLDER IS ASKED BEFORE THE CLOCK. The canary wedged for weeks on a lock
  # a dead process left, because the age check ran first and refused it as
  # "stale, confirm no live runner" — a question the lock's own meta could
  # already answer. A dead holder (pid gone, or the pid now belongs to a
  # process with a different start time or command) is taken over through
  # `fleet_lock_takeover`'s rename-and-verify, and the takeover is alerted so
  # the crash that left it is visible. A live holder still blocks, and the age
  # rule still governs every lock whose holder cannot be judged.
  fleet_run_lock_rc=0
  fleet_lock_acquire "$3" || fleet_run_lock_rc=$?
  case $fleet_run_lock_rc in
    0) return 0 ;;
    2)
      printf 'roundhouse: could not record the run lock evidence at %s; refusing to run without it\n' \
        "$3" >&2
      return 75
      ;;
  esac
  fleet_lock_holder_state "$3"
  fleet_run_lock_state=$fleet_lock_state
  if [ "$fleet_run_lock_state" = dead ]; then
    if fleet_lock_takeover "$3" "$fleet_lock_judged_id"; then
      fleet_run_lock_was=$(printf '%s\n' "$fleet_lock_dead_meta" |
        jq -r '"pid \(.pid // "?") started \(.started_at // "at an unknown time")"' \
          2>/dev/null || printf 'an unreadable holder')
      printf 'roundhouse: took over the run lock at %s from a dead holder (%s)\n' \
        "$3" "$fleet_run_lock_was" >&2
      # Evidence, not a refusal: the run proceeds. The command line stays in
      # the host-local meta and never reaches this replicated record.
      fleet_alert_write "$1" "$2" lock-takeover lock-takeover \
        "took over the run lock from a dead holder ($fleet_run_lock_was); the run it belonged to did not finish" ||
        :
      return 0
    fi
    # Lost the rename race to another run, or the lock changed under the
    # verdict: whoever holds it now is not the holder that was judged.
    return 10
  fi
  fleet_run_lock_age=$(fleet_lock_age_seconds "$3" || printf '')
  fleet_run_lock_stale=$(fleet_run_stale_after "$1" "$2")
  # AN UNKNOWN AGE IS STALE, NOT FRESH. `fleet_lock_age_seconds` answers empty
  # when meta.json is missing or unparsable, and reading that as "under the
  # threshold" wedged every future run on this host silently, forever, at
  # exit 0. It is reachable through the recovery fleet-update/SKILL.md
  # prescribes: `fleet-unlock` removes meta.json BEFORE an rmdir that can
  # fail. A lock directory with no evidence of a live runner is exactly the
  # case the stale branch exists for.
  if [ -z "$fleet_run_lock_age" ]; then
    printf 'roundhouse: a run lock at %s is of unknown age (no readable meta.json); confirm no live runner on this host, then remove it\n' \
      "$3" >&2
    return 75
  fi
  if [ "$fleet_run_lock_age" -gt "$fleet_run_lock_stale" ]; then
    if [ "$fleet_run_lock_state" = live ]; then
      printf 'roundhouse: a live run (pid %s) has held the run lock at %s for %ss, past the %ss threshold; it may be hung — confirm, stop it, then remove the lock\n' \
        "$(fleet_lock_meta_field "$3" pid)" "$3" "$fleet_run_lock_age" \
        "$fleet_run_lock_stale" >&2
    else
      printf 'roundhouse: a run lock at %s is %ss old; confirm no live runner on this host, then remove it\n' \
        "$3" "$fleet_run_lock_age" >&2
    fi
    return 75
  fi
  return 10
}

fleet_lock_age_seconds() {
  # Seconds since the lock was taken, or empty when there is no usable meta.
  # The staleness THRESHOLD is keyed on the full cadence, never the fast
  # interval, and a lock past it is reported as a distinct stale-lock refusal
  # naming the recovery ("confirm no live runner on this host, then release
  # it") — not as a live runner, which is how every later run gets stuck.
  lock_meta="$1/meta.json"
  [ -f "$lock_meta" ] || return 1
  lock_started=$(jq -r '.started_at // empty' "$lock_meta" 2>/dev/null || true)
  [ -n "$lock_started" ] || return 1
  lock_epoch=$(jq -r --arg at "$lock_started" -n \
    'try ($at | fromdateiso8601) catch empty' 2>/dev/null || true)
  [ -n "$lock_epoch" ] || return 1
  printf '%s\n' "$(($(date +%s) - lock_epoch))"
}

fleet_validate_fetch_url() {
  # Store content reaches `git`/`jj` as an argument. Accept only the forms this
  # system can reason about; never an option-looking, whitespace-bearing,
  # credential-bearing, query-bearing, or alternate-transport (ext::, …)
  # string. The query-string refusal was the config-file validator's alone
  # until the `.sync` block was deleted with the v1 subsystem; it belongs on
  # the predicate, so both the store's own reads and any future config get it.
  case ${1:-} in
    '' | -* | *[[:space:]]* | *'?'*) return 1 ;;
  esac
  printf '%s\n' "$1" | grep -qE \
    '^((https|ssh)://[^@]+|[A-Za-z0-9._-]+@[A-Za-z0-9._-]+:[A-Za-z0-9._~/-]+|(file://)?/[A-Za-z0-9._~/-]+)$'
}

fleet_allowed_paths_filter='
  def haspath($p): try (getpath($p[:-1]) | type == "object" and has($p[-1])) catch false;
  def allowed_paths: (.allowed // .keys // []) | map(split("."));
  # An allowed key collides with an excluded namespace when either is a prefix
  # of the other. One predicate, so every writer of a managed config key can
  # never drift into disagreeing about what "widening" means.
  def excluded_collisions:
    ((.excluded_namespaces // []) | map(split("."))) as $excluded |
    [allowed_paths[] as $key | $excluded[] as $namespace |
      select($key[:($namespace | length)] == $namespace or
        $namespace[:($key | length)] == $key)];
'

fleet_quote_is_content_address() {
  # fleet_quote_is_content_address TOKEN [STORE] — is TOKEN a commit id in
  # STORE's own history? PROOF, never shape.
  #
  # This exists because the reverse — exempting a token because its LENGTH
  # looks like a digest — is not safe: a 40-character lowercase-hex API token
  # and a git commit id are the same string shape, so a length test would let a
  # real credential into permanent replicated history. The question that can be
  # answered honestly is "does this name an object this repository already
  # contains", and a token that does names something every peer can already
  # read, so publishing it discloses nothing.
  #
  # WITHOUT A STORE THERE IS NO EXEMPTION. `fleet_record_quote_ok`'s free text
  # (findings/, holds) has no repository context, so nothing there is ever
  # exempt — the strictest answer for the surface a human types prose into.
  case $1 in
    '' | *[!0-9a-f]*) return 1 ;;
  esac
  # 40 exactly: a git/jj commit id. Not a prefix (a short id is under the
  # entropy floor and never reaches here) and not 64 — a sha256 content digest
  # has no cheap proof available, so it gets no exemption either.
  [ "${#1}" -eq 40 ] || return 1
  [ -n "${2:-}" ] || return 1
  [ -n "$(jj -R "$2" log -r "$1" --no-graph -T 'commit_id ++ "\n"' \
    2>/dev/null | head -1)" ]
}

fleet_quote_is_secret() {
  # fleet_quote_is_secret TEXT [STORE] — mechanical backstop to agent-side
  # redaction, not the primary control: named secret classes plus one bounded
  # high-entropy check. Every field a record replicates passes through here,
  # under the same 400-byte cap.
  #
  # STORE is optional and is used for exactly one thing: proving a
  # high-entropy token is a commit id this repository already contains
  # (`fleet_quote_is_content_address`). The sweep passes it because it is
  # walking a store; the free-text guard does not, and gets no exemption.
  #
  # NORMALIZE FIRST, because every check below is line-oriented `grep` and the
  # input is attacker-influenced free text (a `$2`/`$3` handed to
  # `fleet-finding`/`fleet-hold`, a commit description). A token split across a
  # newline — `eyJ…\n…` — evaded every pattern, and an embedded NUL truncated
  # the match; collapsing newlines to spaces and stripping NUL makes the whole
  # quote one line so a split token is seen whole.
  quote_text=$(printf '%s' "$1" | tr -d '\000' | tr '\n' ' ')
  case $quote_text in *'-----BEGIN'*) return 0 ;; esac
  if printf '%s' "$quote_text" |
    grep -qE 'eyJ[A-Za-z0-9_=-]*\.[A-Za-z0-9_=-]+\.[A-Za-z0-9_=-]*'; then
    return 0
  fi
  # `ghr_` is a real GitHub token prefix and was missing from the alternation.
  if printf '%s' "$quote_text" |
    grep -qE '(^|[^A-Za-z0-9_-])(ghp_|gho_|ghu_|ghs_|ghr_|github_pat_|glpat-|xoxb-|xoxp-)[A-Za-z0-9_-]{8,}'; then
    return 0
  fi
  if printf '%s' "$quote_text" | grep -qE '(^|[^A-Za-z0-9_-])sk-[A-Za-z0-9]{16,}'; then
    return 0
  fi
  if printf '%s' "$quote_text" | grep -qE '(^|[^A-Za-z0-9])AKIA[0-9A-Z]{16}'; then
    return 0
  fi
  # Bounded entropy heuristic: one 32+ run of `[A-Za-z0-9_]`. Neither `/` nor
  # `-` is in the class, on purpose: a store path (`store.run/roster.<id>`) and
  # a hyphenated UUID or hostname (`…/store-bf513ef6-0107-492a-ba74-…`) are not
  # secrets, and including those separators joined their short segments into one
  # long token that false-positived every path and dashed id — refusing to
  # publish a perfectly ordinary remote URL. A real hex or base64url secret is
  # still a 32+ alnum/underscore run; a JWT (base64url with dots) has its own
  # explicit pattern above. And the bar is no longer "mixes lower, upper AND
  # digits": a single-case hex secret (lower+digit, or upper+digit) is
  # high-entropy too and slipped through the all-three requirement, while a
  # letters-only single-case run (a jj change id is `k`-`z`, no digit) is NOT
  # flagged, which is why change ids in trailers stay publishable.
  #
  # ONE EXEMPTION, and it is PROVED rather than assumed: a whole token that
  # names a commit this repository already contains. The heuristic used to flag
  # a bare git commit id as single-case hex high-entropy and refuse the guarded
  # publish — and `fleet-checkpoint`'s own description quotes one, so a guard
  # that fires on the most ordinary string in a version-control system is a
  # guard people learn to route around. That is the failure this closes. It is
  # closed by asking the repository, not by measuring the string: a 40-character
  # lowercase-hex credential and a commit id are the same shape, so a length
  # test would publish the credential.
  #
  # `grep -oE` yields maximal runs, so each token below is a WHOLE token — a
  # secret that merely opens with 40 hex arrives as one longer run and is
  # accounted for as itself.
  quote_hits=$(printf '%s' "$quote_text" | grep -oE '[A-Za-z0-9_]{32,}' |
    awk '(/[0-9]/ && /[A-Za-z]/) || (/[a-z]/ && /[A-Z]/) { print }')
  [ -n "$quote_hits" ] || return 1
  # EVERY candidate has to be accounted for. One token this store cannot
  # explain is a secret, however many of its neighbours are commit ids.
  # shellcheck disable=SC2086 # the charset excludes whitespace; one token per word
  for quote_token in $quote_hits; do
    fleet_quote_is_content_address "$quote_token" "${2:-}" || return 0
  done
  return 1
}

fleet_store_id_at() {
  # fleet_store_id_at <store> <revset> — the GENESIS COMMIT ID of the ancestry
  # under <revset>: the root of `::<rev>` with jj's virtual root excluded.
  #
  # §7.5: `store_id` IS the genesis commit id (or, after a re-root, the id of
  # the checkpoint this host started from). It is UNFORGEABLE rather than merely
  # secret — a minted token could simply be CONTAINED by a hostile store, but
  # producing a store with a given genesis means producing that commit. An
  # attacker who knows your store_id still cannot substitute a store for it.
  # A marker FILE could be copied into a hostile store; a genesis commit cannot.
  jj -R "$1" log -r "roots(::($2) ~ root())" --no-graph -T 'commit_id ++ "\n"' \
    2>/dev/null | head -1
}

fleet_store_id() {
  # This store's own genesis, read from PUBLISHED history only — the bookmark
  # or the remote, never `@`. A store between fleet-init and fleet-enroll has a
  # working copy carrying the scaffold and no genesis at all, and answering
  # with @ there would name a commit that carries no roster and was signed by
  # nobody. That empty answer IS the pre-genesis state §12 starts in.
  fleet_store_id_at "$1" \
    'heads(bookmarks(exact:"main")) | present(main@origin)'
}

fleet_store_id_assert() {
  # §7.5 is a COMPARISON, not a presence check, and it is the ONLY thing
  # standing between the fleet and a foreign store: `jj git clone` performs no
  # check whatsoever on remote content — a clone of an unrelated repository
  # succeeds silently. Two roundhouse fleets pointed at one remote would
  # otherwise share one `hosts/vireo.yaml` path between two different machines.
  assert_actual=$(fleet_store_id "$1")
  assert_expected=$(fleet_identity_get store_id)
  [ -n "$assert_expected" ] || return 0
  [ "$assert_expected" = "$assert_actual" ] || {
    printf 'roundhouse: store identity mismatch at %s (identity.yaml expects %s, store genesis is %s)\n' \
      "$1" "$assert_expected" "${assert_actual:-none}" >&2
    return 1
  }
}

fleet_write_store_scaffold() {
  # The §2 store root, written once by fleet-init on a fresh root: the `-text`
  # attribute that keeps line endings out of the value digest (§7.2), a
  # .gitignore that protects the COLOCATED GIT side from an agent running
  # `git add -A` (jj's own auto-track does not need it), and a README for
  # whoever opens the repository.
  #
  # NO IDENTITY MARKER FILE. The fleet discriminator is the genesis commit id
  # (§7.5), compared against identity.yaml's `store_id`.
  printf '%s\n' '*  -text' >"$1/.gitattributes"
  printf '%s\n' '.DS_Store' '*.swp' '*~' '*.sock' '*.tmp' '.roundhouse.*' \
    >"$1/.gitignore"
  cat >"$1/README.md" <<'EOF'
# roundhouse fleet store

This repository is the desired-state store for a roundhouse agent fleet.
Enrolled hosts read desired state from it, converge their own machine, and
publish what they applied back into it.

## Machine-managed

Every change rides a signed commit from an enrolled host and passes that
host's review gates before any machine applies it. A hand edit is unsigned
and unreviewed, so the next host to fetch it holds or refuses the item
instead of converging on it.

## What is never inside

Secrets, credentials, tokens, or key material. Agent transcripts or session
content. Host identity files: the node key each machine mints for itself is
host-local by design and is never synced. The roster names its PUBLIC key.

## Keep this repository private

The store names every machine in the fleet and the state each one runs. Hosts
refuse their first push to a remote that answers unauthenticated reads.

Operator documentation lives in the roundhouse plugin docs (the `fleet-agents`
skill), not in this repository.
EOF
}

# Doctrine carried forward with no code left to carry it, so the phase that
# re-implements each one does not have to re-derive it from a deleted file:
#
# - A failed SIGNED commit exits 65 rather than falling back to unsigned. A
#   store that records signing and holds the key either produces a signed
#   commit or writes nothing at all.
# - Verification is pinned to real ssh-keygen and to the host-local KRL read
#   FRESH on every invocation, never to whatever repo config recorded at init:
#   a third-party signer (1Password's op-ssh-sign, observed live) rejects the
#   revocation argument, and a revoked key then verifies clean.
# - The run's starting jj operation id is captured deliberately WITHOUT
#   `--ignore-working-copy`: that flag suppresses the colocated auto-import,
#   so the newest operation predates jj seeing the store's refs, and restoring
#   to it exports an empty view — deleting the bookmarks outright (observed
#   with real jj 0.44).
# - A failed remote-visibility probe is NOT evidence of privacy. Only an
#   authentication refusal proves the remote is gated; unreachable, DNS
#   failure and timeout are inconclusive and must never satisfy the
#   first-push gate.
# - Moving a store writes its alert BEFORE the push and rolls that commit back
#   when the push fails, and refuses a target that is not the same store
#   (marker) or carries a divergent history (ancestry, either direction).
