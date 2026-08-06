# Unattended Privileged Updates — Design

Status: draft for review · 2026-08-06
Owner: roundhouse (broker, policy, fleet-update), with a scheduling
touchpoint shared with the fleet-sync design (sibling spec, 2026-08-05).

## Purpose

Let scheduled, unattended maintenance runs apply privileged package work —
apt upgrades, winget machine-scope upgrades, and macOS packages/casks that
reach `sudo` (Visual Studio Code and kin) — with no human present at run
time. The human's role moves entirely to setup: one-time per-host broker
enrollment plus explicit per-action policy activation. Run-time approval is
replaced by the broker's sealed-plan mechanics and publisher-bound trust,
never by relaxed checks.

## Current state (what exists, what blocks)

The broker is already mechanically capable of unattended operation:

- POSIX: a sudoers grant names the exact broker executable with an empty
  argument string — no password per action once enrolled.
- Windows: a signed-intent queue polled by the enrolled service account on
  a schedule — no UAC per action once enrolled.
- Every request is a sealed plan naming a semantic action from a fixed
  catalog; there is no arbitrary-command shape.

Two things block unattended privileged updates today:

1. **Doctrine, not mechanics.** `fleet-update` states that unattended runs
   "skip protected/privileged actions — those stay interactive by design,"
   and the scheduled prompt instructs the agent to skip anything requiring
   elevation. The broker itself imposes no such restriction.
2. **Binding shape, for macOS payloads only.** The policy catalog binds
   each action to a constraint, and the shapes differ:
   - `apt.upgrade-package.v1` / `winget.upgrade-machine-package.v1` bind to
     a **source/channel closure hash** — the source is pinned, not the
     version. Already auto-update-compatible.
   - `macos.install-signed-pkg.v1` and `sealed-cask-payload-v1` bind to the
     **exact payload**: size + sha256 + package id + version + Apple Team ID
     signature. New release ⇒ new bytes ⇒ human re-enrollment. Incompatible
     with auto-update by construction.

## Design

### 1. Per-action `unattended` flag in the policy catalog

Add one column to the policy catalog: `unattended|attended` (default
`attended`). An action may execute inside a scheduled run only when it is
enrolled, owner-activated, **and** flagged `unattended`. Flipping the flag
is an owner ceremony with the same consent weight as activation.

Doctrine changes that ride on it:

- `fleet-update` unattended section: scheduled runs execute protected
  actions that carry the `unattended` flag through the identical sealed
  pipeline (seal → verify-preconditions → submit → verify post-state);
  everything else remains skipped and surfaces in the log/doctor. The
  scheduled prompt's "skip anything requiring interactive elevation"
  becomes "privileged work runs only through active unattended-flagged
  broker actions; skip anything else that would require elevation."
- Failure handling is unchanged: fail closed, journal, surface at the next
  doctor run. No retry-with-different-shape, no fallback to sudo.

### 2. Provenance-anchored bindings — the standard, not an option

A byte-hash-per-version binding on software that updates is a design
error, full stop: it turns every release into a human ceremony and
defeats the point of scheduled updates. No host has ever enrolled under
the current shape, so there is no migration — the byte-bound payload
actions are **replaced**, not augmented. The general principle: **the
provenance that installed a thing vouches for its updates.** Signedness
of the individual payload is not the axis; the anchor is. Three anchor
shapes cover every scenario:

**Channel-bound (the common case)** — anything owned by a package
manager: apt packages, winget packages, Homebrew formulae **and casks,
signed or not**. The binding pins the manager + source/tap + package
token (the shape `apt.upgrade-package.v1` already has); integrity comes
from the manager's own attestation chain — apt repo signatures, winget
source attestation, Homebrew's tap-published checksums verified on every
download. An unsigned cask is not an orphan: its tap is its provenance,
exactly as a .deb's repo is. Whatever the enrolled channel currently
ships for that token is authorized, at any version.

**Publisher-bound** — payloads installed *outside* any manager (a
directly-downloaded signed pkg): Apple code-signature validity
(`pkgutil --check-signature`, `codesign --verify` / `spctl --assess`),
**Team ID** and **package/bundle identity** equal to enrolled values,
notarization accepted, size ceiling as sanity bound. Enrollment is
seeded from an observed genuine payload, so the owner never types a
Team ID by hand.

**Byte-pinned (rare, attended)** — a one-off artifact with neither a
managed channel nor a publisher identity. Nothing can vouch for its next
version, so it stays attended — and it should be the exception that
prompts "why isn't this in a manager?"

**.app placement and ownership**: casks whose app is user-writable in
`/Applications` update as the ordinary Homebrew user — no broker
involvement at all. The broker enters only where the update genuinely
crosses a privilege boundary (cask pkgs reaching Homebrew's hardcoded
sudo, system-owned app trees via the `macos-cask-app` record, machine
scope winget). The existing bridge machinery keeps Homebrew as the
transaction owner; only its byte-match gate changes to the channel
binding, with the artifact re-verified against the tap attestation at
apply time.

### 2a. Install is the authorization; installed means updatable

A human-directed install is a two-part consent captured at one moment:
install *this*, and keep it current from the *same provenance*. When the
owner says "install X" through a managed channel, the install ceremony
records or extends the channel binding for X's token — no second ceremony
later, no per-version anything. Symmetrically, everything already
installed at enrollment time is seeded into the bindings from the
observed inventory (its manager and source are known), so "already
installed" and "just installed" converge on the same rule: **if it's on
the machine through a known provenance, keeping it current is
pre-authorized.** Removal of the binding is the deliberate act, not
renewal.

### 3. Enrollment stance change

`fleet-hosts` step 5 stops being "skip by default." New stance: broker
enrollment is **recommended for any host that should self-update**, and
the add-host flow asks once: "should this machine apply privileged package
updates unattended?" Yes ⇒ enroll broker + activate the OS-appropriate
upgrade actions + flag them unattended, in one consented ceremony.
`railyard:setup` surfaces the same question during first-run. Doctor gains
a check: a host with a sync/update schedule but no unattended-capable
broker enrollment is reported as drift (the schedule silently skipping
privileged work forever is exactly the kind of quiet failure doctor
exists to name).

### 4. What stays interactive, deliberately

- Enrollment, activation, unattended-flagging, revocation — all owner
  ceremonies at the local password/UAC boundary.
- `macos.apply-system-setting.v1` and any action without the unattended
  flag.
- Anything failing closed: a payload with the right Team ID but wrong
  identity, an unnotarized build, a policy file that fails integrity
  checks — these wait for a human, they never degrade.

## Security analysis

- Layers unchanged: sudoers → exact broker binary; fixed semantic catalog;
  owner-activated policy; sealed plans with fresh preconditions; fail
  closed everywhere.
- The delta is the binding shape: byte-pin → provenance-pin
  (channel-bound for managed software, publisher-bound for direct signed
  payloads). Residual risk is a compromised channel or publisher — a
  poisoned tap, a hijacked repo, a stolen signing cert — which is
  precisely the exposure the owner already accepts by using that manager
  or vendor interactively today; unattended operation adds no new trust
  root, it only removes the human from a loop where the human was
  rubber-stamping the same provenance check. Mitigations stay the
  channel's own (repo signatures, tap checksums, notarization,
  revocation) plus the sealed pipeline's fresh-precondition and
  post-state checks. The owner's decision is per-provenance at
  install/enrollment, never per-version.
- apt/winget gain no new trust: their channel bindings already express
  publisher-level trust; they only gain the unattended flag.
- The unattended flag never widens *what* an action may do — only *when*
  it may run.

## Rollout

1. Broker + policy catalog: add the flag, add the v2 macOS bindings,
   extend the enrollment/preview/status vocabulary
   (`preview-privilege-upgrade` already exists for policy evolution).
2. Skill doctrine: fleet-update (unattended section + scheduled prompt),
   fleet-hosts (step 5 stance), railyard setup + doctor checks.
3. Per-host enrollment pass: one sitting, all hosts that should
   self-update — each host's ceremony covers broker install, action
   activation, unattended flags.
4. First supervised scheduled run per OS family, then hands-off.

## Open items (for the implementation plan)

1. Exact verification command set for v2 on current macOS (pkgutil /
   codesign / spctl flag sets, stapled-vs-online notarization checks) and
   their offline behavior.
2. Homebrew cask flow under channel binding: the bridge currently
   byte-matches before substituting the protected artifact; it needs the
   match keyed on tap+token with the artifact re-verified against the
   tap's published checksum at apply time. Also: what attests the tap
   itself (git provenance of the tap checkout, official-vs-third-party
   taps), and whether third-party taps need a separate consent tier.
3. Windows parity for publisher binding: winget channel bindings may
   already suffice; confirm whether Authenticode-publisher pinning is
   needed for any machine-scope package outside winget's attestation.
4. Version-floor guard: whether v2 bindings should refuse downgrades
   (installed version regression) as an anti-rollback measure.
5. Interaction with fleet-sync's scheduler: one shared schedule entry
   driving both sync and updates vs separate entries; jitter and overlap
   locking.
