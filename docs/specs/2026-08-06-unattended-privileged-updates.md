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

### 2. Publisher-bound bindings for macOS payloads (v2)

New binding shape for the two macOS payload actions
(`macos.install-signed-pkg.v2`, `sealed-cask-publisher-v1`): drop the byte
digest and version pin; keep and extend the signature checks that already
exist in the broker:

- Apple code-signature validity (`pkgutil --check-signature`, and
  `codesign --verify` / `spctl --assess` for app bundles),
- **Team ID** must equal the enrolled value,
- **package/bundle identity** must equal the enrolled value,
- notarization ticket present (spctl accepted),
- size ceiling retained as a sanity bound.

Trust moves from "the exact bytes the owner enrolled" to "any genuine
package from this publisher with this identity" — Apple's signing chain
takes over the integrity role the sha256 played. v1 byte-bound actions
remain in the catalog for payloads the owner wants version-pinned; v2 is
what an auto-updating app enrolls as. Enrollment of a v2 binding is
seeded from an observed genuine payload (the enrollment ceremony verifies
the seed package and records its team/identity), so the owner never types
a Team ID by hand.

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
- The delta is confined to binding shape on two macOS actions: byte-pin →
  publisher-pin. Residual risk is a compromised publisher certificate or
  malicious signed update — the same exposure as every macOS app
  auto-updater, mitigated by notarization and Apple's revocation
  machinery. The owner chooses per-package whether that trade is
  acceptable (v2) or not (stay v1, stay attended).
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
2. Homebrew cask flow for publisher-bound payloads: the bridge currently
   byte-matches before substituting the protected artifact; v2 needs the
   match keyed on identity+team with the artifact re-verified at apply
   time.
3. Windows parity for publisher binding: winget channel bindings may
   already suffice; confirm whether Authenticode-publisher pinning is
   needed for any machine-scope package outside winget's attestation.
4. Version-floor guard: whether v2 bindings should refuse downgrades
   (installed version regression) as an anti-rollback measure.
5. Interaction with fleet-sync's scheduler: one shared schedule entry
   driving both sync and updates vs separate entries; jitter and overlap
   locking.
