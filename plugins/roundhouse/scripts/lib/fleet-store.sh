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

fleet_lock_acquire() {
  # One lock shape for every entry point: the directory is the mutex, the meta
  # file is the evidence doctor and the stale-lock check read.
  lock_dir=$1
  mkdir "$lock_dir" 2>/dev/null || return 1
  chmod 0700 "$lock_dir"
  jq -S -n --arg host "$(fleet_host_name)" --argjson pid "$$" \
    --arg started "$(fleet_now)" \
    '{host:$host,pid:$pid,started_at:$started}' >"$lock_dir/meta.json" 2>/dev/null || true
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

fleet_lock_holder_gone() {
  # True when the lock names a pid on THIS host that no longer exists. The pid
  # was already being recorded and never read: staleness was time-only, so a
  # SIGKILLed or power-cut run wedged the host for two full cadences while a
  # slow-but-live run looked identical. `kill -0` distinguishes them in one
  # syscall.
  #
  # The host name is compared because the lock lives beside a store path that
  # a second instance root could share; a pid from another machine says
  # nothing about this one, so it falls back to the time-only answer.
  lock_meta="$1/meta.json"
  [ -f "$lock_meta" ] || return 1
  [ "$(jq -r '.host // empty' "$lock_meta" 2>/dev/null)" = "$(fleet_host_name)" ] ||
    return 1
  lock_pid=$(jq -r '.pid // empty' "$lock_meta" 2>/dev/null || true)
  case $lock_pid in
    '' | *[!0-9]*) return 1 ;;
  esac
  ! kill -0 "$lock_pid" 2>/dev/null
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
