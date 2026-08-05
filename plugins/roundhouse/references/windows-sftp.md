# Protected enrollment and Windows SFTP operations

This reference covers the owner-operated path from node identity preparation
through enrollment, recovery, upgrade, and revocation. Agent commands prepare,
inspect, submit closed requests, and retrieve public results. They never obtain
or relay a sudo or Administrator password, accept a UAC prompt, activate a
policy, or perform a real enrollment ceremony.

## Trust boundaries

Three identities remain distinct:

- The originating fleet node owns one passphrase-less Ed25519 private key in a
  nonsynced, owner-only local state directory. It never leaves that node.
- An isolated owner signing account controls the offline fleet CA. The CA
  private key is absent from fleet nodes, normal agent configuration, service
  accounts, and unattended 1Password access.
- Each Windows target has a dedicated standard request SID. It is not an
  Administrator and is different from the ordinary profile SID used by the
  non-elevated S4U task.

The signed plugin release authenticates enrollment source. The protected
installed broker, policy generation, tasks, OpenSSH configuration, ACLs, and
native-canary receipts are separately attested host state. Updating or
uninstalling the plugin neither upgrades nor revokes that protected state.
There is no stored administrator credential.

Ordinary Windows inventory reports transport state as a
`protected-local-observation`. The collector accepts only the exact
ACL-protected local `candidate.receipt`, detached CMS, and `readiness` files
under `MachineUtilities-Sftp-Public` and binds them to current local broker
projections and the configured route. At promotion, the detached CMS signer
certificate must cover the candidate's original `issued-at`/`expires-at`
interval. After promotion, those exact signed bytes are historical
authorization evidence: status revalidates their hashes, signer, and original
certificate coverage, not whether the signing certificate is valid today.
Historical evidence cannot authorize a new repair, verification, or revocation.

Public U6 v1 bytes do not expose the native-canary digests or evidence needed
for portable independent verification. A non-Windows caller, copied receipt,
unverified ACL, or user-owned identity-overlay receipt can therefore never
establish transport readiness. Remote `privilege-status` uses a separate fresh,
signed broker control described below; it does not reinterpret copied local
readiness.

## Prepare and certify each node

Run `machine-utilities prepare-privilege-identity` on the originating node.
The fixed helper creates the private key only below its platform state root and
emits a public-only certificate request. Repository, plugin-cache, cloud-sync,
symlinked, wrong-owner, or group/world-readable locations fail closed. Do not
copy the private key into a request, ticket, backup, peer, target, plan, log, or
secret-manager item.

Move only the public request into the isolated signer account. Before every
ceremony, obtain the expected SHA-256 for `scripts/certify-ssh-node` from the
authenticated release on a separate trusted path. Compare it to the protected
`helper.sha256` and independently hash the executing helper inside the signing
account. `certify-ssh-node status` must report that exact digest before
`certify-ssh-node sign` consumes the bounded request on standard input.

Inspect the manifest before signing and the certificate after signing. Verify
the unique `NODE@FLEET-DOMAIN` signing principal, only the fixed POSIX/Windows
endpoint principals, source-address restriction, serial, finite validity, CA
fingerprint, CA generation, and absence of extra extensions. Return only the
certificate, public CA key, manifest, and other public receipts. A normal
1Password SSH agent may protect an interactive owner key, but unattended
runtime ignores `SSH_AUTH_SOCK`; the fleet CA must not be offered by that
agent. Renewal is manual: keep the old identity until the replacement passes
representative POSIX and Windows canaries.

The protected Windows `AuthorizedPrincipalsFile` maps the fixed
`machine-utilities-windows` certificate principal to the dedicated
`MachineUtilitiesRequest` account. The signed request identity remains that
account and its pinned SID; the account name is not an additional certificate
principal.

## Prepare enrollment

Use these read-only surfaces from either Codex or Claude:

```text
machine-utilities privilege-status HOST STATUS.jsonl
machine-utilities prepare-privilege-enrollment HOST PREPARATION.json
machine-utilities preview-privilege-upgrade HOST UPGRADE.json
machine-utilities preview-privilege-revocation HOST REVOCATION.json
```

`prepare-privilege-enrollment` names only fixed repository entrypoints, modes,
public artifacts, and the human boundary. It performs no activation. Compare
all release hashes with `integrity.json`; compare the target's installed
protected generation and native-canary receipts separately.

On Linux, preview the privilege broker and POSIX SSH transport, then complete
their local passworded-sudo ceremonies. macOS may enroll the bounded ordinary
dispatcher and, after local human activation, its two cataloged root actions:
`macos.install-signed-pkg.v1` and `macos.apply-system-setting.v1`. The former
can prepare an enrolled exact app bundle/package payload; it never grants root
Homebrew or arbitrary sudo. WSL always reports
`unsupported_security_boundary`; never install a broker in a distribution or
fall back through Windows, a shell, or an interactive task.

On Windows, the ordinary target user first runs the fixed profile-task
registration helper for that user's SID. Then, at the Windows console or an
already trusted owner session, inspect both Administrator previews and complete
the UAC-gated broker and SFTP enrollment ceremonies. Confirm the host-key
fingerprint locally; never accept `ssh-keyscan` as enrollment proof. Enrollment
stages the account, CA/KRL trust, chroot, fixed slots, ACLs, quota, task
definitions, OpenSSH configuration, and firewall restriction. No status is
`ready` until the effective SFTP-only configuration, native canaries, exact
candidate signature, and final verification all pass.

## Windows owner ceremony

Use the protected copy of `enroll-windows-sftp.ps1` fixed by
`bootstrap.receipt`; do not run a repository or plugin-cache copy. The staging
root is `C:\ProgramData\MachineUtilities-Sftp-Bootstrap`. Its controller inputs
have fixed names: `controller.intent`, `controller.intent.p7s`,
`controller.receipt`, and `controller.receipt.p7s`.

1. Stage the exact controller intent and its detached CMS signature through the
   authenticated bootstrap procedure. The intent fixes the target host,
   dedicated request SID, CA/KRL generations, management CIDRs, protected U3
   digests, task contracts, ACL contracts, quota, OpenSSH contract, and its
   finite authorization interval.
2. In an interactive Administrator PowerShell session, run the protected script
   with `-Preview`. Preview is read-only. Inspect the complete candidate and
   record its SHA-256, request SID, host-key fingerprint, management CIDRs,
   signer thumbprint, generation hashes, and all protected contract hashes.
3. Run the same protected script with `-Install -Confirmation SHA256` for a new
   enrollment, or `-Repair -Confirmation SHA256` for a replacement generation.
   The confirmation is the exact previewed candidate hash. This UAC-gated
   transaction stages and canaries the generation and publishes the exact
   candidate in an awaiting-signature state; it cannot promote `ready`.
4. Export the exact candidate bytes from
   `C:\ProgramData\MachineUtilities-Sftp-Public\candidate.receipt`. Rehash them
   outside the target and require the hash to equal both the previewed hash and
   the active pending candidate hash. Do not normalize newlines, reserialize,
   copy from prose, or sign a reconstructed file.
5. In the isolated controller-signing environment, inspect those exact bytes
   again and create a detached CMS signature whose signer certificate covers
   the candidate's original `issued-at`/`expires-at` interval. Neither the fleet
   SSH CA private key nor the controller-signing private key may exist on the
   target, an agent host, or unattended automation.
6. Through the protected staging procedure, place only the unchanged candidate
   bytes at `controller.receipt` and their detached signature at
   `controller.receipt.p7s`. Preserve the fixed filenames, protected ACLs, and
   byte identity. Do not stage a private key, certificate-authority credential,
   password, or alternate receipt.
7. Before the signed intent expires, run the protected script with `-Verify` in
   an interactive Administrator session. Verification requires exact candidate
   bytes, the configured signer, signer-certificate coverage of the original
   interval, current intent authority, generation/task/ACL/OpenSSH/firewall
   state, and native canaries before it promotes `ready`.

If any step fails, treat the ceremony as not promoted. The request account must
remain or be returned to disabled and the managed firewall must remain or be
returned to closed. Use `-Status` to retain the exact failure/history; if either
activation gate is open after a failure, stop and use the fixed owner recovery
path before retrying. Start again with a fresh preview and, when authority
expired or inputs changed, a freshly signed intent. Never extend authority by
changing a timestamp, resigning different candidate bytes, or treating a
historical ready receipt as current mutation authority.

Only after `-Verify` reports `ready` may the controller copy the exact
`request-sid` from that authenticated signed intent/candidate receipt into
`automation_transport.request_sid`. The configured SID is a pin, like the host
key fingerprint. Never derive it from a local account lookup, Codex inventory,
an unsigned/static readiness file, a profile target SID, or a previous
generation. A missing pin or any response mismatch fails closed. During repair
or rotation, keep the old pin until the new signed generation is promoted, then
update it explicitly.

## Windows transport contract

The configured `windows-sftp` route uses an explicit host, port, request user,
pinned host key, and management CIDRs. It bypasses user SSH configuration,
agents, proxies, jump hosts, and control sockets. It fixes
`IdentitiesOnly=yes`, `IdentityAgent=none`, `BatchMode=yes`, strict host-key
checking, no local command, no multiplexing, and no forwarding.

The dedicated SID is chrooted behind `ForceCommand internal-sftp`. It can write
only the four preallocated paths below, with `commit` transferred last:

```text
/ingress/slot/request
/ingress/slot/request.sig
/ingress/slot/payload
/ingress/slot/commit
```

It can read only sanitized normal `/results/REQUEST-ID.result` files and, for
the closed readiness control, `/results/REQUEST-ID.readiness`. Readiness never
uses `.result`, `active`, `last`, or directory listing. Exec, shell, SCP,
arbitrary subsystem, PTY, environment requests, X11, forwarding, tunneling,
agent forwarding, directory creation, and listing are outside the contract. An
unrelated broad SSH firewall rule cannot widen the certificate's signed source
restriction or the managed per-account restriction.

`machine-utilities privilege-status HOST STATUS.jsonl` sends the normal signed
`request|1` envelope with action `broker.readiness.v1`, an empty payload, fixed
`windows-system-v1`/`LocalSystem` context, and detached broker/policy/
constraint/generation inputs. It uses the same four-file slot and commit-last
order as an action. The controller accepts only the matching `.readiness`
result, binds its request ID, configured request SID, request principal, and
pinned transport, and rejects stale, duplicate, unsorted, malformed, oversized,
or non-canonical rows. A success is valid for at most 300 seconds and contains
fresh protected action/token preconditions and profile constraints. The exact
five-line `fresh_probe_failed` result remains unavailable evidence and never
becomes a ready snapshot.

This remote result attests the protected broker generation, policy and
constraint hashes, WinGet/provider context, tasks, transport, native canary,
action/token probes, and profile constraints. It deliberately does not claim a
controller policy-proposal digest, context-canary digest, or action-specific
constraint-set digest. Therefore it cannot replace ordinary Windows inventory
or precondition capture for a mixed schema-4 plan. Ordinary inventory remains
on the configured Codex Desktop lane; it is never routed through SFTP.

## Closed actions and results

Seal only action-context pairs advertised by fresh readiness. A protected
request contains a normalized action ID, policy token when required, plan and
request identity, public certificate identity, freshness, and digests. It does
not contain a command, executable, argv, PowerShell, environment, working
directory, source selector, installer selector, dependency control, or fallback
context.

Use `verify-privilege-plan` immediately before `submit-privilege-plan`. Machine
WinGet actions have an empty payload. `profile.apply-managed-bundle.v1` alone
has a bounded profile payload built by `profile-bundle`. The controller writes
and closes all bytes before the commit marker; the protected task reopens and
rehashes them before use.

If submission is interrupted or a terminal reply is lost, use
`lookup-privilege-result PLAN OPERATION-INDEX OUTPUT`. Lookup performs only a
freshly authenticated result query or bounded SFTP `get`; it never resubmits
the request. Keep `partial` and `stale` evidence. The public Windows result is
bound to the request, plan, action, enrollment epoch, and protected-result
digest without exposing protected journal detail.

## WinGet and profile limits

WinGet is the required V1 Windows machine-package provider. The protected
generation fixes the catalog identity, machine scope, provider generation, and
source-delegated dependency boundary. The approved source still chooses the
applicable manifest, installer, dependencies, and root-installer feature
effects inside the authorized package/version channel. The controller cannot
change dependency behavior or claim independently observed installer or
closure evidence.

The profile task runs as the configured ordinary user with S4U, non-elevated,
and without network or encrypted-file access. A profile bundle may contain
only authorized managed config, agent definition, standalone-skill, and local
marketplace desired-record content. It excludes credentials, secret-backed
templates, installed plugin caches, internal agent state, startup/task paths,
and arbitrary overlays. Staging a plugin desired record reports
`manager_activation_pending` until the next ordinary user session completes
manager activation.

## Recovery and upgrade

Readiness distinguishes transport, node certificate, broker, policy,
action-context, and profile readiness. Preserve the observed state:

- `needs_enrollment`: inspect preparation and complete the local owner ceremony.
- `drifted`: do not submit; inspect protected artifacts and use the fixed repair preview.
- `transport_unavailable`: distinguish sleep, preboot lock, network, host-key,
  certificate, OpenSSH, firewall, account, and chroot failures.
- `unsupported_context` or `unsupported_security_boundary`: stop without fallback.
- `partial`: retain useful records and recover the terminal result.
- `stale`: do not infer success; use result lookup or owner recovery.

For an upgrade, enter draining first, reject new submissions, and keep result
lookup available while any active request reaches a protected terminal state.
Then inspect the fixed upgrade/repair previews and complete the local owner
password/UAC ceremony. Protocol 0 remains readable for readiness, lookup,
drain, and revocation; return `needs_broker_upgrade` only for an action-context
the observed protocol cannot execute.

If Windows SFTP or a task is damaged, keep the request account disabled and the
managed firewall closed until the fixed repair verifies the whole effective
configuration again. Codex Desktop remains an ordinary interactive-user lane,
not a logged-off recovery or privilege fallback. FileVault/BitLocker preboot
and a sleeping host remain unreachable until the owner unlocks or wakes them.

## Revocation and CA rotation

Normal revocation drains, rejects new staging, retrieves terminal evidence,
then removes the adapter grant. Windows transport revocation disables the
account and closes the managed firewall first, then removes the key, chroot
rights, and managed objects before the broker-owned disabled account and roots
are removed. Emergency revocation may end reachability sooner but must record
the resulting partial or stale request evidence.

Revoke one node certificate by generating an owner-controlled KRL and proving
its expected generation active on every reachable target. A peer node remains
valid. Rotate a CA with a staged dual-CA window: enroll and canary the new
public trust, renew nodes, distribute the new KRL/trust generation, prove at
least one owner-authorized path throughout, and only then remove the old CA.
Losing or compromising the CA requires full-fleet replacement; it cannot be
repaired by a plugin update.
