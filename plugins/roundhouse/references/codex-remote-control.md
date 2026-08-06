# Codex Desktop remote control

> **Check the interop lane first.** For a target whose registry entry
> declares `wsl_interop_via`, CLI-shaped work defaults to the WSL interop
> lane (SSH to the sibling, `cd /mnt/c`, full-path `cmd.exe /c` — native
> processes, any harness). This contract is the fallback for Desktop-app
> surface work, or when WSL is absent or unreachable.

Use this only for a machine whose configured transport is
`codex-remote-control`. Never substitute WSL or SSH.

## Task-control capability check

Task-control tools may be loaded lazily. Only when the selected targets include
a `codex-remote-control` machine, discover and check the app tools, including
`list_projects`, `create_thread`, `wait_threads`, and `set_thread_archived`;
reuse that capability
result for the bounded operation. Reuse only the tool-availability result,
never a `list_projects` response or project ID. An absent eager tool listing is not evidence
that a tool is unavailable. Classify failure precisely:

- `tool_surface_missing`: lazy discovery proves a required app tool is absent;
- `host_offline`: `list_projects` reports the configured host in
  `unavailableHosts` or its source as unreachable;
- `saved_project_missing`: the host and source are reachable, but
  `list_projects` has no saved project matching both the configured
  remote-control host and exact native path;
- `native_evidence_unavailable`: only WSL evidence exists for the configured
  native Windows target;
- `task_creation_failed`: `create_thread` fails for the matched project or its
  client task never resolves through `wait_threads`;
- `task_cleanup_failed`: the completed task cannot be archived, or unexpected
  task-owned worktree cleanup cannot finish safely;
- `executor_mismatch`: the task runs but the installed executor version or
  integrity hashes do not match; or
- `executor_or_plugin_failure`: the verified task runs but a manager command
  or requested-version postcondition fails.

Do not collapse these states into a generic task-control failure.

## Shared model-routing dispatch

Before every visible Codex task creation and every task message or follow-up,
invoke the installed runtime skill `railyard:model-routing`; it is the
only routing authority used here. Send exact
`contractVersion: "railyard/model-routing/v1"`. Do not call a provider
router, copy model constants, effort defaults, a transport matrix, scoring,
state, or cache lookup into Roundhouse. If the skill or that exact
compatible contract is absent, stop the affected Codex dispatch with
`model_routing_capability_unavailable`; retain local/SSH evidence but never
create an unbound task or omit model/effort controls.

Roundhouse remains the sole sender for its native remote actions and
retains host/project matching, Windows-native execution, executor readiness,
payload/chunk validation, and cleanup. The routing request is bounded,
content-free policy metadata and includes:

- `callerKind: "fleet"`, a stable `senderOwnerDigest`, unique
  request/action ID, `adapterId` (`codex-task-create` or
  `codex-task-message`), and `dispatchKind` (`task_create` or `task_message`);
- the selected host/task/transport readiness, separate execution-host and
  target-platform identities, exact carrier transport, bounded destination
  work-class digest and `workShape`, privacy/context constraints, and the
  standalone task/run budget scope or accepted orchestrator lease;
- a one-use visible-task authority receipt for `task_create`. A user policy,
  catalog entry, prior task, or caller Boolean is not task authority; and
- for `task_message`, the destination task identity, its resolver-owned prior
  route receipt with prior model/effort, and whether the bounded work class
  continues or changes.

For a work-starting task creation or message, set `budgetEffect: "start"` and
follow the returned sequence exactly: resolve, `admit(requestId)`,
`claim-dispatch`, perform the native action, then reconcile the returned
receipt. Pass the returned validated adapter/path/model/effort controls to the
Codex task action verbatim. A missing/unselectable control, requested-versus-
actual mismatch, or incompatible path uses only the resolver's disclosed
fallback or blocks; never silently inherit or substitute a route.

A status request, non-expanding clarification, cancellation, or narrowing that
the adapter attests does not start work instead uses `budgetEffect: "none"` and
obtains an immutable no-start action receipt. It does not reserve, claim, or
authorize later work. A message that expands the objective, acceptance checks,
files, unit volume, provider/carrier calls, or expected duration is active work:
before sending, use `budgetEffect: "adjust_active"` to admit the additional
conservative ceiling against the existing attempt, then send and reconcile it;
an active-work adjustment creates no new dispatch claim.
If it cannot fit, narrow, cancel, wait for newly admitted work, or block.

Every same-task chunk retrieval is a fresh `task_message` routing boundary.
Re-resolve its bounded chunk work class and prior route before each follow-up;
inherit only when the fresh decision selects the exact attested winning prior
model and effort for the unchanged class. Status replies never prove that later
chunk work is admitted. Preserve the existing 48 KiB limits, ordering, digest
validation, and task correlation after routing.

When the returned path requires a visible-provider bridge, it is two separately
accounted actions. First resolve/admit/claim an acknowledgement-only bootstrap,
consume the visible-task authority, create the task with its returned controls,
verify tool-returned task identity, and compare the secret-free acknowledgement.
That bootstrap forbids mutable work. Only after it succeeds, re-resolve,
admit, and claim the provider-local activation/follow-up; reconcile each phase
separately. A bootstrap failure settles only that attempt and never authorizes
activation. Same-provider or verified plaintext paths use the single returned
native action instead.

## Fresh-task project binding

Every remote-control operation starts a new visible task. Never resume,
unarchive, or send a follow-up to an older task as a recovery path, even when
that task used the same host, project, or operation type.

Do not use `list_threads`, `read_thread`, `set_thread_archived`, `fork_thread`,
`handoff_thread`, or `send_message_to_thread` to select or recover the task.
Follow-ups are allowed only on the new task created for the current operation.

Call `list_projects` immediately before creation and select exactly one object
whose `hostDisplayName` matches the configured `codex_host` and whose
environment-native path matches the configured project path. Retain its opaque
`hostId`. Pass that same object's `projectId`
verbatim to `create_thread` with `environment: { type: "local" }`; do not type,
reconstruct, cache, or copy an ID from prose, memory, readiness metadata,
config, or an earlier listing. Keep the selected object and the creation result
together as evidence.

If `create_thread` returns `Unknown projectId`, call `list_projects` once more
and discard every prior project object and ID. Rematch the exact host and path,
then retry once with that newly returned object's `projectId`, whether or not
the value changed. If either call used an ID other than the same response's
matched object, record a controller invocation error. If the fresh rematch is
missing or unreachable, classify that exact state; if the one retry fails,
classify `task_creation_failed`. Do not reuse an old task or substitute another host.
When creation returns a client task ID, wait only for that setup to yield its
real task and host IDs; all waits and follow-ups must remain correlated to that
new task.

## Parent-owned task cleanup

The controller that creates the task owns its full lifecycle. After it captures
and validates the terminal result, deletes any task temporary payload, and
needs no further follow-up, it archives that exact new task in the same
operation. Never leave a successfully completed child visible for later reuse.

`environment: { type: "local" }` uses the saved checkout and normally creates
no task worktree. If a task nevertheless reports an owned worktree, do not assume archive removes it: verify its changes are integrated or explicitly
handed off, then use the host's supported handoff or worktree cleanup and wait
for success before archiving. Never use raw filesystem deletion or force
cleanup of dirty or unintegrated work. Leave the task and worktree visible and
record `task_cleanup_failed` on conflict or cleanup failure. Archive failure
also records `task_cleanup_failed`; it never authorizes reuse or unarchiving of
an older task.

## Routine marketplace refresh

An explicit named-plugin refresh does not require a full native inventory or
sealed plan. Resolve the host, saved project, marketplace, and applicable Codex
and Claude harnesses from the controller's configured scope. Use the capability check and fresh-task binding above,
create a new visible task in the configured saved project, and run native PowerShell only.
Before and after each
applicable harness, capture `codex plugin list --json`; for Claude, capture
`claude plugin list --json`. Freeze a de-duplicated set of every installed
record owned by the exact marketplace. In the task, run only these mutation
commands in order for each applicable harness:

```powershell
# Codex
codex plugin list --json
codex plugin marketplace upgrade MARKETPLACE --json
node "EXACT-ROUNDHOUSE-PLUGIN-ROOT\scripts\codex-plugin-hooks.mjs" update EACH_INSTALLED_PLUGIN@MARKETPLACE

# Claude
claude plugin list --json
claude plugin marketplace update MARKETPLACE
claude plugin update EACH_INSTALLED_PLUGIN@MARKETPLACE --scope user
```

Reject any frozen ID without the exact `@MARKETPLACE` suffix. Attempt every
frozen marketplace plugin even when another one fails; do not install entries
absent from the pre-refresh set. Update `roundhouse@novotnyllc` last when
present, then recapture and re-resolve its installed executor. The Codex add is
idempotent and preserves approved stable hook keys. Require each pre-existing marketplace record to remain
present with enabled state and Claude scope preserved; require outside-marketplace
records to be unchanged. Report every before/after version. If native PowerShell cannot find
`claude`, mark only the Claude harness unavailable. WSL or SSH are prohibited.
Treat Codex and Claude harness failures independently: preserve each before/after
record and attempt the other applicable harness. Do not update a runtime,
settings, skills, provenance, or another marketplace, and do not claim success from
manager output alone. Record a failed postcondition as
`executor_or_plugin_failure` while preserving before-state and command output;
keep executor version/hash mismatch separate as `executor_mismatch` only when
an executor load or verification was attempted. This manager-native refresh
does not require or preflight the Roundhouse executor, because that
would prevent it from repairing a stale Roundhouse installation.

For an explicit Codex hook approval, first verify the exact native Machine
Utilities root against `executor.json`, then invoke only its helper:

```powershell
pwsh -NoProfile -File "VERIFIED-ROUNDHOUSE-ROOT\scripts\apply-windows.ps1" `
  -ApproveCodexPluginHooks PLUGIN@MARKETPLACE `
  -ExecutorRequirementPath executor.json
# The verified PowerShell boundary runs exactly:
node "VERIFIED-ROUNDHOUSE-ROOT\scripts\codex-plugin-hooks.mjs" approve PLUGIN@MARKETPLACE
```

The helper writes only current matching trust hashes and verifies them. Do not
approve through WSL, a controller-local helper, or an unverified plugin root.

Use the full protocol below for inventory, broad reconciliation, settings,
provenance, conversions, ambiguous scope, and sealed-plan mutations.

1. Treat the initiating machine's config as authoritative. Resolve one host,
   one section, and the applicable projects/policy locally; include that
   bounded JSON object and the raw-config SHA-256 in the task prompt.
2. Read `integrity.json` from the authenticated merged source and record its
   exact plugin version, manifest SHA-256, and ordered file hashes. Executor
   inspection is read-only: on the target, locate the active
   `roundhouse@novotnyllc` cache and run
   `pwsh -NoProfile -File scripts/apply-windows.ps1 -VerifyExecutor
   -ExecutorRequirementPath executor.json`. If the version or any hash differs, return
   `executor_update_required` and run no collector or mutation.
3. Updating the executor is a separately approved bootstrap action. Use
   `codex plugin marketplace upgrade novotnyllc --json` followed by the current
   integrity-verified helper:
   `node "EXACT-ROUNDHOUSE-PLUGIN-ROOT\scripts\codex-plugin-hooks.mjs" update roundhouse@novotnyllc`.
   It snapshots hook trust before running the exact native plugin add. The only
   fallback is a separately approved Roundhouse self-update from an
   integrity-verified release that predates this helper: after the marketplace
   upgrade, run exactly
   `codex plugin add roundhouse@novotnyllc --json`, end that task, start a
   fresh task, and verify the `0.5.1` executor and integrity manifest before any
   other mutation. Never use raw add as a fallback for another plugin or once
   the helper is available. For Claude local or
   SSH use `claude plugin marketplace update novotnyllc` followed by
   `claude plugin update roundhouse@novotnyllc --scope user`. End the
   bootstrap task and start a fresh task before loading any Roundhouse
   skill or script.
4. Use Codex Desktop project discovery. Match the configured host and the
   environment-native project path. If no saved project matches, stop and tell
   the user to add that checkout as a project in Codex Desktop on the target.
   Record `available`, `missing`, or `unreachable` with the opaque host/project
   IDs, configured host ID, exact native path, and expected source in a
   mode-0600 metadata file, then use `roundhouse
   record-codex-readiness`; never inspect or edit Codex's internal databases.
5. Create a visible task against that saved project using its local checkout,
   not a new worktree: inventory must observe the real host.
6. Tell the task to use the verified installed Roundhouse collector, native
   PowerShell on Windows, and no WSL. Request one inventory section per task.
   Pass the initiating config's raw SHA-256 as `-ControllerConfigDigest`; the
   worker records both that digest and its bounded worker-config digest. Pass
   `-AllowAuthVerify` only for an explicitly requested auth inventory after
   the bounded config and controller digest have been verified.
   The task writes the complete JSONL to a private target-local temporary file
   and computes its byte count, record count, and SHA-256.
7. If setup returns a client task ID, wait for the real task ID before using
   task tools. Wait in bounded intervals. Leave approvals and needs-attention
   prompts to the user.
8. If the payload is at most 48 KiB, return it with its byte count and SHA-256.
   Otherwise return only a manifest, then use follow-up messages on the same
   task to retrieve numbered chunks of at most 48 KiB. Each chunk carries its
   index, byte count, and SHA-256. Concatenate in order, verify the full byte
   count and SHA-256, and tell the task to delete the temporary file.
9. Validate every returned JSONL record locally. Reject a wrong schema,
   config digest, host ID, section, oversized record, missing/duplicate chunk,
   or truncated response. Never merge an unvalidated partial response into a
   good snapshot.
10. Enrich the returned project and operation records with the real saved-project,
   task, and correlation IDs using `record-codex-readiness`.

For an approved mutation, generate the bounded target config with
`roundhouse worker-config HOST DOMAIN OUTPUT`, seal the plan, and send
only that config, the plan, the controller-derived executor status, and their
byte counts/SHA-256 values. The native task must verify its configured
`expected_hostname` and `expected_user`, then run `apply-windows.ps1` with the
exact plan-file SHA-256 and plan ID. Accept success only from validated JSONL
containing the matching final `apply:PLAN-ID` record, executor hashes, both
configuration digests, and semantic post-state. Prose is never success
evidence. The worker recaptures its own trusted preflight. If an operation or
postcondition fails, it stops the remaining operations and returns an
authoritative partial result with fresh post-inventory whenever collection is
still possible; validate and preserve that evidence even though the task
failed.

Codex remote control is an ordinary, interactive schema-2 lane only.
`apply-windows.ps1` rejects semantic actions and every protected broker field,
even if those fields are injected into an otherwise ordinary operation.
Schema-3 and schema-4 plans never use the Codex task, the legacy SSH workspace,
WSL, SCP, a shell fallback, or another execution context.

Protected Windows operations use only the enrolled `windows-sftp` route. The
controller signs a closed request and transfers exactly the four preallocated
slot files `request`, `request.sig`, `payload`, and `commit`; `commit` is last.
Machine-package and inventory actions have an empty payload. Only
`profile.apply-managed-bundle.v1` has a nonempty payload. The four exact
chroot-relative upload paths are `/ingress/slot/request`,
`/ingress/slot/request.sig`, `/ingress/slot/payload`, and
`/ingress/slot/commit`. Polling performs only bounded `get` attempts for
`/results/REQUEST-ID.result`; it never resubmits. The client accepts only the
fixed sanitized public-result fields bound to the request, plan, action,
epoch, and protected-result digest, and preserves both that protected digest
and the exact public-projection digest in operation/final evidence. The SFTP
batch contains no directory creation, listing, execution, SCP, or shell
command.

The shared lifecycle commands are `privilege-status`,
`prepare-privilege-enrollment`, `verify-privilege-plan`,
`submit-privilege-plan`, `lookup-privilege-result`,
`preview-privilege-upgrade`, and `preview-privilege-revocation`. They are also
the Claude vocabulary. Preparation and previews are inert and stop before a
human password or UAC boundary. They never request or relay an Administrator
credential. `lookup-privilege-result` performs result-only reads and never
recreates or resubmits a slot. See `windows-sftp.md` for the owner-operated
enrollment-to-revocation runbook.

For a configured Windows SFTP route, `privilege-status` is not a Codex
inventory task. It creates a fresh signed `broker.readiness.v1` request, uses
the same four exact slot uploads with `commit` last, and performs bounded reads
only from `/results/REQUEST-ID.readiness`. The response must match the request
ID, configured ceremony-derived `request_sid`, request principal, and pinned
route; it must be canonical, sorted, unique, and unexpired. It never reads the
normal `.result`, `active`, `last`, or a directory listing. An unavailable or
invalid response yields unavailable readiness, not a fallback to Codex, local
files, WSL, or ordinary SSH.

Plugin integrity and protected host attestation answer different questions.
`integrity.json` authenticates the installed plugin source and controller
executor. Protected readiness separately attests the Administrator-owned
broker generation, policy, WinGet provider context, tasks, SFTP configuration,
ACLs, and native-canary receipts. A plugin update does not upgrade protected
code, and removing the plugin does not revoke its broker, request account,
certificate trust, policy, or tasks.

Ordinary Windows inventory still surfaces SFTP state as a
`protected-local-observation`: exact local public-file ACLs, a controller-signed
candidate, its detached CMS signer, and current local readiness/route
projections are checked together. Once promoted, the candidate is historical
authorization evidence. Validation binds its exact bytes and verifies that the
signer certificate covered the original `issued-at`/`expires-at` interval; it
does not require that certificate to be valid today and does not turn history
into current mutation authority. U6 v1 public bytes do not publish the native
canary evidence needed for portable proof, so copied files and user-owned
identity-overlay receipts remain non-authoritative.

The remote readiness control is a separate fresh protected-broker observation.
It returns broker/generation/policy/constraint/WinGet/provider hashes, live
task/transport/native-canary gates, action/token preconditions, and profile
constraints. It intentionally reports no controller policy-proposal digest,
context-canary digest, or action-specific constraint-set digest. It therefore
cannot replace the ordinary inventory and precondition evidence needed to seal
or verify a mixed schema-4 plan. The ordinary `collect` path remains Codex
Desktop and is never silently routed through SFTP.

Build logged-off profile payloads with `roundhouse profile-bundle`.
The builder compiles each destination's handler, artifact, manager, and logical
identity; sorts destinations ordinally; binds the expected live presence,
digest, and manager; and emits an uncompressed length-prefixed manifest and
payload. It rejects case collisions, traversal, links, target-local overlays,
credentials, caches, internal state, startup/task paths, and secret-backed
templates. Caller identity is not serialized, so Codex and Claude callers
produce identical bytes from identical inputs.

The dedicated SFTP request SID and the non-elevated S4U profile target SID are
different identities. Before staging a profile request, the controller
revalidates the active protected token and its target SID, profile-root ID,
entry-map digest, marketplace-set digest, deletion mode, entry cap, and byte
cap from fresh readiness. It then validates every canonical manifest field,
payload offset/length/digest, compiled destination/handler/artifact/manager
association, and expected live state. The request SID is never accepted as the
S4U target or as authority to widen the entry map.

`automation_transport.request_sid` is mandatory and fail-closed. Pin it only
from the exact authenticated controller intent/candidate receipt after the
owner completes the Windows `-Preview`, `-Install` or `-Repair`, isolated
detached-signing, staging, and `-Verify` ceremony. Do not infer it from a local
account lookup, Codex or static readiness, the profile SID, or old enrollment
history. A missing pin or a different SID in the fresh remote response rejects
readiness. See `windows-sftp.md` for the fixed filenames and ceremony order;
neither the fleet CA nor controller-signing private key enters automation.

Protected POSIX automation uses the root-owned forced command
`/usr/local/libexec/roundhouse/posix-dispatcher`, which executes only
`/usr/local/libexec/roundhouse/current/scripts/roundhouse
dispatch-posix-request`. The bounded stdin protocol contains either one sealed
ordinary schema-2 plan plus worker configuration or one signed broker envelope;
it has no caller-selected command, executable, shell option, or workspace path.
Linux broker envelopes reach only
`sudo -n /usr/libexec/roundhouse/posix-broker`. macOS supports the
ordinary bounded lane and rejects protected root actions.

Standalone schema-3 plans for each closed APT, WinGet, and profile action are
executed by the same fixed broker path as mixed schema-4 plans. The internal
projection adds only freshly verified UID/SID, certificate source-address,
Windows platform-context evidence, and the matching action/token precondition.
On Windows those fields come from fresh signed SFTP readiness, so logged-off
submission never requires ordinary Codex collection. The projection does not
add an executable, argv, package/source/dependency control, environment, or
fallback context. POSIX
result queries are freshly signed with the current node overlay certificate,
including after renewal or from another enrolled node, while terminal evidence
continues to match the original mutation's journaled identity and certificate.

For upgrade or revocation, enter draining first and reject new submissions.
Readiness and fresh result lookup remain available for protocol 1 and protocol
0 while an active request reaches a protected terminal state; then remove only
the adapter-owned grant. Emergency revocation may remove the grant earlier but
must retain explicit partial or stale evidence. Return `needs_broker_upgrade`
only when the sealed action/context is absent from the observed protocol, not
for readiness, query, drain, or revocation controls.

The controller does not need a local copy of the remote path. Task creation
uses the saved remote project. Cross-host handoff is separate and requires the
same repository to be saved on both source and destination hosts.

Project work is handed off through that project's Git repository and exact
commit. An optional private coordination repository may track pointers and
status across projects, but it does not replace their repositories or provide
their working trees. Never use an unrelated development checkout as the
control project merely because it already exists on the destination.

The native Windows saved-project workflow was exercised on 2026-07-30 with
small byte-for-byte payloads and a 323-record inventory split and exactly
reassembled at record boundaries. Revalidate the protocol if the Desktop task
result limits or task-control surface change.
