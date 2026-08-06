# Unattended Privileged Updates — Design

Status: draft v2 (post-adversarial-review) · 2026-08-06
Owner: roundhouse (broker, policy, fleet-update), with a scheduling
touchpoint shared with the fleet-sync design (sibling spec, 2026-08-05).

## Purpose

Let scheduled, unattended maintenance runs apply privileged package work —
apt upgrades, winget machine-scope upgrades, and macOS packages/casks that
reach `sudo` (Visual Studio Code and kin) — with no human present at run
time. The human's role moves to setup and periodic batched ceremonies:
per-host broker enrollment, explicit policy activation, and confirming
staged binding proposals. Run-time approval is replaced by the broker's
sealed-plan mechanics and provenance-anchored trust, never by relaxed
checks.

## Current state (what exists, what blocks)

The broker is already mechanically capable of unattended operation:

- POSIX: a sudoers grant names the exact broker executable with an empty
  argument string — no password per action once enrolled.
- Windows: a signed-intent queue polled by the enrolled service account on
  a schedule — no UAC per action once enrolled.
- Every request is a sealed plan naming a semantic action from a fixed
  catalog; there is no arbitrary-command shape.
- apt's channel anchor is **root-owned generation state**: protected
  sources.list, pinned keyrings, source-authority records; apt is forced
  onto them. The apt upgrade constraint already carries version bounds
  (`minimum_version|maximum_version|major_ceiling`).
- The Homebrew cask bridge's safety today is byte-matching against a
  **root-owned protected artifact** and executing that artifact — never
  the user-submitted path.

Two things block unattended privileged updates today:

1. **Doctrine, not mechanics.** `fleet-update` states that unattended runs
   "skip protected/privileged actions — those stay interactive by design,"
   and the scheduled prompt instructs the agent to skip anything requiring
   elevation.
2. **Binding shape.** macOS payload actions bind to exact payload bytes +
   version, so every release of an auto-updating app needs a human
   re-enrollment. That per-version ceremony defeats the point of scheduled
   updates and is replaced by this design. (apt/winget channel bindings
   already avoid it.)

## Design

### 1. Unattended flags: per-action gate AND per-binding grant

Two flags, both required, fail closed:

- **Action-level gate** in the policy catalog: `unattended|attended`
  (default `attended`). Flipping it is an owner ceremony.
- **Binding-level grant** on each constraint row: `unattended|attended`
  (default `attended`). This is where the real consent lives — "this one
  third-party-tap cask stays attended" must be expressible, and
  action-level alone (all apt tokens at once) is coarser than the
  per-provenance consent this spec claims.

A scheduled run may execute a protected action only when the action is
enrolled, owner-activated, action-flagged unattended, AND the specific
binding is flagged unattended. The flags never widen *what* an action may
do — only *when* it may run.

Doctrine changes that ride on it:

- `fleet-update` unattended section: scheduled runs execute qualifying
  protected actions through the identical sealed pipeline (seal →
  verify-preconditions → submit → verify post-state); everything else
  remains skipped and surfaces in the log/doctor. The scheduled prompt's
  "skip anything requiring interactive elevation" becomes "privileged
  work runs only through active unattended-flagged broker bindings; skip
  anything else that would require elevation." Rollout must update the
  prompt on already-enrolled hosts in the same pass as the doctrine edit.
- Failure handling is unchanged: fail closed, journal, surface at the
  next doctor run. No retry-with-different-shape, no fallback to sudo.

### 2. Provenance-anchored bindings

The principle stands — **the provenance that installed a thing vouches
for its updates; per-version byte pins on updating software are replaced**
— but the anchor must be state the unprivileged user cannot write. That
is what makes apt's channel binding sound, and what a naive Homebrew
"channel binding" lacks: the tap checkout, Caskroom, and brew prefix are
all owned by the enrolled user. Three anchor shapes:

**Channel-bound, root-anchored (apt, winget)** — already sound: the
binding pins manager + source + token against root-owned source-authority
state. These actions gain the unattended flags and mandatory version
floors (below); nothing else changes.

**Channel-bound, root-anchored (Homebrew — new machinery required)** —
the binding pins tap + token, but verification NEVER trusts the user's
tap checkout or Caskroom. The broker maintains a **root-owned attested
tap snapshot** per enrolled channel: pinned upstream remote URL, fetched
or verified against the upstream remote by root at refresh time, stored
in the protected generation tree. Apply-time rules:

- The expected checksum comes from the root-owned snapshot only.
- **Root never executes a user-owned path.** The bridge copies the
  submitted artifact into root-owned scratch (0700, root-owned ancestors,
  protected-file checks), hashes **the copy**, verifies against the
  snapshot, runs the existing structural package inspections on the copy,
  and installs **the copy**. (This preserves the current bridge's
  load-bearing invariant; the byte-match gate becomes a snapshot-checksum
  gate with identical staging discipline — no TOCTOU window.)
- Casks with `sha256 :no_check` or `version :latest` are unverifiable and
  are **excluded from unattended channel binding**; they stay attended.
- Third-party taps are a **separate consent tier**: named individually in
  ceremonies, never bulk-seeded, never unattended-flagged by default — a
  forgotten `brew tap` must not quietly acquire unattended root.
- Cask/formula **definition text diffs** from the snapshot are the
  unattended safety screen (see §5).

If the snapshot machinery is descoped, the honest fallback is that
unsigned cask pkgs stay attended — there is no third option that is not a
local-user → root escalation.

**Publisher-bound (direct signed payloads outside any manager)** — Apple
code-signature validity (`pkgutil --check-signature`,
`codesign --verify` / `spctl --assess`), **Team ID** and
**package/bundle identity** equal to enrolled values, notarization
accepted, size ceiling as sanity bound. Enrollment is seeded from an
observed genuine payload, so the owner never types a Team ID by hand.
Unattended verification policy (mandatory, not an open item):

- A **stapled** notarization ticket or a successful online assessment is
  required; "no network, no answer" fails closed (journaled), never
  passes.
- Certificate revocation must be checked with bounded staleness: a
  revocation check older than the bound ⇒ the item is held, not applied.

**Byte-pinned (rare, attended)** — a one-off artifact with neither a
managed channel nor a publisher identity. Nothing can vouch for its next
version, so it stays attended — and it should be the exception that
prompts "why isn't this in a manager?"

**Anti-rollback is mandatory for every unattended binding**: the broker
refuses a candidate version lower than the installed version (same
version-comparison discipline the receipt checks already use; apt's
constraint rows already carry the bounds). Deliberate downgrades are an
attended act. No binding authorizes "any version" — the authorization is
"current or newer from this provenance."

**.app placement and ownership**: casks whose app is user-writable in
`/Applications` update as the ordinary Homebrew user — no broker
involvement at all. The broker enters only where the update genuinely
crosses a privilege boundary (cask pkgs reaching Homebrew's hardcoded
sudo, system-owned app trees via the `macos-cask-app` record, machine
scope winget).

### 2a. Install intent seeds proposals; ceremonies mint authority

The owner experience stays "install X once, updates flow forever" — but
the *mechanism* respects the broker's integrity model: policy constraints
live in root-owned, hash-chained generation files that only owner
ceremonies may change, and that stays true.

- A human-directed install through a managed channel **stages a binding
  proposal** (channel, token, anchor evidence) — unprivileged, outside
  the protected tree. It does not touch policy.
- Proposals are **committed only by an owner ceremony** — the existing
  `preview-privilege-upgrade` → generation-upgrade path — at the local
  password/UAC boundary. Ceremonies are batched: "5 pending binding
  proposals: [list]" confirmed as a list, so this is an occasional
  minute, not per-version or per-package pain.
- **Enrollment seeding is a reviewed list, not a yes/no.** At broker
  enrollment, the observed inventory generates proposals for everything
  installed through known provenances; the ceremony displays the full
  list — channels, tokens, counts, third-party taps highlighted for their
  separate tier — and the owner confirms the list. What the owner
  confirms becomes bound; nothing binds silently.
- A compromised or prompt-injected session can therefore stage noise, but
  can never mint authority: the ceremony is the boundary, and the staged
  list is exactly what it reviews.
- Removal of a binding is likewise a deliberate ceremony act — but stale
  bindings are surfaced, not hoarded (§4).

### 3. Enrollment stance change

`fleet-hosts` step 5 stops being "skip by default." New stance: broker
enrollment is **recommended for any host that should self-update**, and
the add-host flow asks once: "should this machine apply privileged
package updates unattended?" Yes ⇒ enroll broker + activate the
OS-appropriate upgrade actions + review-and-confirm the seeded binding
list (2a) in one consented ceremony. `railyard:setup` surfaces the same
question during first-run. Doctor gains checks:

- A host with a sync/update schedule but no unattended-capable broker
  enrollment is drift (a schedule silently skipping privileged work
  forever is a quiet failure).
- A binding whose token is absent from current inventory and desired
  state is drift ("stale authority"), reported for the next batched
  removal ceremony.

### 4. Desired-state seam with fleet-sync

Fleet-sync owns **desired package state** (what should be installed
where, removals propagate by default); the broker owns **authority**
(what may touch root, ceremonies only). They meet at doctor: fleet-sync
removing a package fleet-wide does not and cannot remove the root-owned
binding — doctor reports the orphaned binding as stale authority, and the
owner's next batched ceremony sweeps it. Neither system ever writes the
other's state. (Cross-referenced from the fleet-sync spec's surface
section.)

### 5. Blast radius, audit, and the unattended safety screen

- **Canary-gated rollout, reusing fleet-sync's store**: each OS family
  designates a canary host (registry group). Non-canary hosts apply a
  given (channel, token, version) only after the canary's journaled
  success for that tuple is ≥ N hours old in the store; a journaled
  canary failure holds the tuple fleet-wide. No new infrastructure — the
  store already replicates journals.
- **Per-run cap**: an unattended run applies at most K privileged
  changes; above the cap it journals and holds the remainder for review.
  A normal night is a few packages; fifty is an anomaly regardless of
  provenance.
- **Owner-facing audit**: every unattended privileged apply produces a
  notification line and a doctor-visible record — host, token,
  old → new version, provenance anchor. The human leaves the loop; the
  loop reports back.
- **Definition-diff screening (Homebrew)**: before an unattended
  channel-bound apply, diff the cask/formula definition against the
  root-owned snapshot's prior state and screen the text: URL host
  changes, checksum weakening (`:no_check` appearing), new
  `installer script`/postflight stanzas ⇒ hold attended (fleet-sync's
  held-item semantics). Binary payload diffing stays out of scope; the
  definition diff is the tractable screen, and it is workable unattended
  precisely because it is text.

### 6. What stays interactive, deliberately

- Enrollment, activation, unattended-flagging, binding-proposal
  ceremonies, downgrades, revocation — all owner ceremonies at the local
  password/UAC boundary.
- `macos.apply-system-setting.v1` and any action or binding without both
  unattended flags.
- Held items: `:no_check` casks, flagged definition diffs, over-cap
  remainders, canary failures, stale revocation — held closed for a
  human, never degraded through.

## Security analysis

- Layers unchanged: sudoers → exact broker binary; fixed semantic
  catalog; owner-activated policy in hash-chained root-owned generations;
  sealed plans with fresh preconditions; fail closed everywhere. Root
  never executes or trusts user-owned paths or user-writable metadata —
  the Homebrew snapshot machinery exists precisely to keep that true
  under channel binding.
- Authority minting is ceremony-only (2a); interactive sessions stage
  proposals but cannot commit them, so a compromised session gains no
  standing root authority.
- The residual risk delta is confined to provenance compromise: a
  poisoned upstream tap, a hijacked repo, a stolen-but-not-yet-revoked
  signing cert. That is the same exposure the owner accepts interactively
  today; unattended operation adds no new trust root. Mitigations:
  root-anchored snapshots (local tampering excluded), mandatory
  anti-rollback, bounded-staleness revocation checks, definition-diff
  screening, canary gating, per-run caps, and full audit.
- Scheduler environment: broker env-sanitization already assumed hostile
  callers; the scheduled entries run as the enrolled user with no TTY
  (sudoers grants must not require one), and macOS checks that need
  network or keychain access follow the fail-closed offline policy in §2.

## Rollout

1. Broker + policy catalog: binding-level unattended column, action gate,
   version floors on all unattended bindings, Homebrew root-owned tap
   snapshot + staged-copy bridge flow, proposal staging + ceremony
   commit vocabulary (extends `preview-privilege-upgrade`).
2. Skill doctrine in lockstep: fleet-update (unattended section +
   scheduled prompt, including already-enrolled hosts), fleet-hosts
   (step 5 stance + seeded-list ceremony), railyard setup + doctor
   (drift checks from §3–4, audit surface from §5).
3. Per-host enrollment pass: one sitting per host — broker install,
   action activation, seeded binding list review, unattended flags.
4. Supervised first runs: one attended scheduled run per OS family, plus
   one logged-off Windows canary proving the session-0 winget path,
   before hands-off. Canary gating (§5) stays on permanently.

## Open items (for the implementation plan)

1. Exact verification command sets on current macOS (pkgutil / codesign /
   spctl flags, stapled-vs-online notarization detection, how to perform
   a bounded-staleness revocation check) and their measured offline
   behavior.
2. Homebrew snapshot mechanics: refresh cadence and transport (root
   fetching the tap remote vs verifying a fetched mirror), disk budget,
   and how snapshot refresh interacts with the definition-diff screen
   (refresh IS the diff moment).
3. Windows parity details: session-0 winget behavior per source type,
   whether Authenticode-publisher pinning is needed for any machine-scope
   package outside winget's attestation, and the RoundhouseRequest
   account's network dependencies while logged off.
4. Canary parameters: N-hour gate default, canary host selection per OS
   family (always-on preference), and behavior when the canary is the
   only host of its family.
5. Per-run cap K default and the shape of the held-remainder review.
6. Scheduler seam with fleet-sync: one shared schedule entry driving both
   sync and updates vs separate entries; jitter and overlap locking.
