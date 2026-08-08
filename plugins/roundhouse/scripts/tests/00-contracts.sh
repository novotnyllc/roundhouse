# roundhouse self-check — doctrine, skill and reference contract assertions.
#
# Sourced by scripts/test-roundhouse in a fixed order; not a
# standalone test file. See that driver for why.
# shellcheck shell=bash

fleet_agents_skill="$script_dir/../skills/fleet-agents/SKILL.md"
remote_control_reference="$script_dir/../references/codex-remote-control.md"
fleet_agents_text=$(cat "$fleet_agents_skill")
remote_control_text=$(cat "$remote_control_reference")

for routing_consumer in fleet-agents fleet-auth fleet-chezmoi fleet-inventory fleet-projects fleet-update; do
  routing_consumer_text=$(cat "$script_dir/../skills/$routing_consumer/SKILL.md")
  assert_contains "$routing_consumer_text" 'railyard/model-routing/v1'
done

assert_contains "$fleet_agents_text" 'ROUNDHOUSE_CONFIG'
assert_contains "$fleet_agents_text" '${XDG_CONFIG_HOME:-$HOME/.config}/roundhouse/config.json'
assert_contains "$fleet_agents_text" "use each"
assert_contains "$fleet_agents_text" 'guess an SSH alias'
assert_contains "$fleet_agents_text" 'fleet-wide inventory/readiness matrix'
assert_contains "$fleet_agents_text" 'update every installed'
assert_contains "$fleet_agents_text" 'Do not install other catalog entries'
assert_contains "$fleet_agents_text" 'EACH_INSTALLED_PLUGIN@MARKETPLACE'
assert_contains "$fleet_agents_text" 'freeze a'
assert_contains "$fleet_agents_text" 'outside-marketplace record to be unchanged'
assert_contains "$fleet_agents_text" 'Update `roundhouse@novotnyllc` last'
assert_contains "$fleet_agents_text" 'Report before/after versions per'
assert_ordered "$fleet_agents_skill" \
  'codex plugin marketplace upgrade MARKETPLACE --json' \
  'update-codex-plugin EACH_INSTALLED_PLUGIN@MARKETPLACE'
assert_contains "$fleet_agents_text" 'never send or interpolate'
assert_contains "$fleet_agents_text" '"$TARGET_CLI" verify-executor'
assert_contains "$fleet_agents_text" 'previously resolved and verified `"$TARGET_CLI"`'
assert_contains "$fleet_agents_text" 'integrity-gated `-ApproveCodexPluginHooks` path'
assert_contains "$fleet_agents_text" 'only pre-helper fallback'
assert_contains "$fleet_agents_text" 'codex plugin add roundhouse@novotnyllc --json'
assert_ordered "$fleet_agents_skill" \
  'claude plugin marketplace update MARKETPLACE' \
  'claude plugin update EACH_INSTALLED_PLUGIN@MARKETPLACE --scope user'
# railyard is broken without compound-engineering, so the routine refresh
# converges that dependency under its existing mutation authorization.
assert_contains "$fleet_agents_text" 'A host that carries `railyard` REQUIRES the `compound-engineering` plugin'
assert_contains "$fleet_agents_text" 'version 3.20.0 or newer'
assert_contains "$fleet_agents_text" '`EveryInc/compound-engineering-plugin`'
assert_contains "$fleet_agents_text" 'not a separate consent'
assert_contains "$fleet_agents_text" 'do not install it on a
harness that does not carry railyard'
assert_contains "$fleet_agents_text" \
  'codex plugin marketplace add EveryInc/compound-engineering-plugin --json'
assert_contains "$fleet_agents_text" \
  'codex plugin add compound-engineering@compound-engineering-plugin --json'
assert_contains "$fleet_agents_text" \
  'claude plugin marketplace add EveryInc/compound-engineering-plugin'
assert_contains "$fleet_agents_text" \
  'claude plugin install compound-engineering@compound-engineering-plugin --scope user'
assert_contains "$fleet_agents_text" 'Report the dependency as a converged item'
assert_contains "$remote_control_text" '`list_projects`'
assert_contains "$remote_control_text" '`create_thread`'
assert_contains "$remote_control_text" '`wait_threads`'
assert_contains "$remote_control_text" '`wait_threads`, and `set_thread_archived`'
assert_contains "$remote_control_text" 'An absent eager tool listing is not evidence'
assert_contains "$remote_control_text" '`railyard:model-routing`'
assert_contains "$remote_control_text" '`contractVersion: "railyard/model-routing/v1"`'
assert_contains "$remote_control_text" '`callerKind: "fleet"`'
assert_contains "$remote_control_text" '`codex-task-create` or'
assert_contains "$remote_control_text" '`codex-task-message`'
assert_contains "$remote_control_text" '`task_create` or `task_message`'
assert_contains "$remote_control_text" '`senderOwnerDigest`'
assert_contains "$remote_control_text" 'visible-task authority receipt'
assert_contains "$remote_control_text" 'execution-host and'
assert_contains "$remote_control_text" 'target-platform identities'
assert_contains "$remote_control_text" 'work-class digest'
assert_contains "$remote_control_text" '`budgetEffect: "start"`'
assert_contains "$remote_control_text" '`admit(requestId)`'
assert_contains "$remote_control_text" '`claim-dispatch`'
assert_contains "$remote_control_text" 'adapter/path/model/effort controls'
assert_contains "$remote_control_text" '`budgetEffect: "none"`'
assert_contains "$remote_control_text" '`budgetEffect: "adjust_active"`'
assert_contains "$remote_control_text" 'Every same-task chunk retrieval is a fresh `task_message` routing boundary'
assert_contains "$remote_control_text" 'visible-provider bridge'
assert_contains "$remote_control_text" 'acknowledgement-only bootstrap'
assert_contains "$remote_control_text" 'provider-local activation/follow-up'
assert_contains "$remote_control_text" 'model_routing_capability_unavailable'
assert_contains "$remote_control_text" 'Do not call a provider'
assert_contains "$remote_control_text" 'model constants'
assert_contains "$remote_control_text" 'transport matrix'
assert_contains "$remote_control_text" 'state, or cache lookup'
assert_contains "$remote_control_text" 'Every remote-control operation starts a new visible task'
assert_contains "$remote_control_text" 'Never resume,'
assert_contains "$remote_control_text" 'Reuse only the tool-availability result'
assert_contains "$remote_control_text" 'never a `list_projects` response or project ID'
assert_contains "$remote_control_text" 'Pass that same object'
assert_contains "$remote_control_text" '`projectId`'
assert_contains "$remote_control_text" '`hostDisplayName` matches the configured `codex_host`'
assert_contains "$remote_control_text" 'Retain its opaque'
assert_contains "$remote_control_text" 'environment: { type: "local" }'
assert_contains "$remote_control_text" '`Unknown projectId`'
assert_contains "$remote_control_text" 'controller invocation error'
assert_contains "$remote_control_text" 'whether or not'
assert_contains "$remote_control_text" 'discard every prior project object and ID'
assert_contains "$remote_control_text" 'reconstruct, cache, or copy an ID'
assert_contains "$remote_control_text" '`set_thread_archived`'
assert_contains "$remote_control_text" '`fork_thread`'
assert_contains "$remote_control_text" '`handoff_thread`'
assert_contains "$remote_control_text" 'Follow-ups are allowed only on the new task'
assert_contains "$remote_control_text" 'The controller that creates the task owns its full lifecycle'
assert_contains "$remote_control_text" 'Never leave a successfully completed child visible for later reuse'
assert_contains "$remote_control_text" 'do not assume archive removes it'
assert_contains "$remote_control_text" 'Never use raw filesystem deletion or force'
assert_contains "$remote_control_text" 'client task ID'
assert_contains "$remote_control_text" '`unavailableHosts`'
assert_contains "$remote_control_text" 'matching both the configured'
for native_status in tool_surface_missing host_offline saved_project_missing native_evidence_unavailable task_creation_failed task_cleanup_failed executor_mismatch executor_or_plugin_failure; do
  assert_contains "$remote_control_text" "$native_status"
done
assert_contains "$remote_control_text" 'does not require or preflight the Roundhouse executor'
assert_ordered "$remote_control_reference" \
  'codex plugin marketplace upgrade MARKETPLACE --json' \
  'codex-plugin-hooks.mjs" update EACH_INSTALLED_PLUGIN@MARKETPLACE'
assert_contains "$remote_control_text" 'applicable Codex'
assert_contains "$remote_control_text" 'Claude harnesses'
assert_contains "$remote_control_text" 'native PowerShell only'
assert_contains "$remote_control_text" '`claude plugin list --json`'
assert_contains "$remote_control_text" 'de-duplicated set'
assert_contains "$remote_control_text" 'Attempt every'
assert_contains "$remote_control_text" 'do not install'
assert_contains "$remote_control_text" 'outside-marketplace'
assert_contains "$remote_control_text" 'Update `roundhouse@novotnyllc` last'
assert_contains "$remote_control_text" 'Report every before/after version'
assert_contains "$remote_control_text" 'mark only the Claude harness unavailable'
assert_contains "$remote_control_text" 'WSL or SSH are prohibited'
assert_contains "$remote_control_text" 'Treat Codex and Claude harness failures independently'
case $remote_control_text in
  *'Claude is not applicable to `codex-remote-control`'*)
    fail "remote-control routine still excludes native Claude"
    ;;
esac
assert_ordered "$remote_control_reference" \
  'claude plugin marketplace update MARKETPLACE' \
  'claude plugin update EACH_INSTALLED_PLUGIN@MARKETPLACE --scope user'
assert_contains "$fleet_agents_text" 'may run the native Claude CLI in the visible native PowerShell'

# --- desired-state sync: the runbook and the dispatch table, together ---

# The skill carries the RUNBOOK for the verbs the CLI actually dispatches. The
# doc and the dispatch table fall together or this suite goes green while the
# skill lies — which is exactly what the excision-era stub was guarding against
# in the other direction.
assert_contains "$fleet_agents_text" '## Desired-state sync'
assert_contains "$fleet_agents_text" 'docs/specs/2026-08-06-dsc-storage-design-v2.md'
# Nothing user-facing calls this system a version of itself. It is presented
# unversioned; only the spec FILENAME carries the label it was written under.
case ${fleet_agents_text//docs\/specs\/2026-08-06-dsc-storage-design-v2.md/} in
  *[Vv]2*) fail "fleet-agents presents the system as a version of itself" ;;
esac
for sync_excised_command in sync-init sync-refresh-signers sync-fetch \
    sync-run-begin sync-lease sync-verdict sync-apply sync-materialize \
    sync-effective sync-status sync-pending sync-finding; do
  ! grep -Fq -- "$sync_excised_command" "$cli" ||
    fail "the CLI entrypoint still carries $sync_excised_command"
  case $fleet_agents_text in
    *"$sync_excised_command"*)
      fail "fleet-agents still documents the v1 verb $sync_excised_command" ;;
  esac
done

# Every verb the runbook names is a verb the CLI dispatches, and every fleet
# verb the CLI dispatches is named in the runbook. A documented command that
# does not exist and an undocumented command that does are the same bug.
for fleet_documented_verb in fleet-init fleet-enroll fleet-verify-remote \
    fleet-set-remote fleet-seed fleet-doctor fleet-explain fleet-run \
    fleet-review fleet-apply fleet-accept fleet-hold fleet-pending \
    fleet-journal fleet-finding fleet-lock fleet-unlock fleet-rollback \
    fleet-adopt-pin fleet-add fleet-join fleet-remove fleet-renew \
    fleet-reparent fleet-reconstitute fleet-checkpoint fleet-reroot; do
  grep -Eq "^  $fleet_documented_verb\)" "$cli" ||
    fail "fleet-agents documents $fleet_documented_verb, which has no dispatch arm"
  assert_contains "$fleet_agents_text" "$fleet_documented_verb"
done
for fleet_dispatched_verb in $(grep -Eo '^  fleet-[a-z-]+\)' "$cli" |
    tr -d ' )'); do
  assert_contains "$fleet_agents_text" "$fleet_dispatched_verb"
done

# The enrollment sequence, in order, and the gate in the middle of it. The
# first push REFUSES without fleet-verify-remote, so a runbook that omits it
# walks every new host into a refusal it has no name for.
#
# `fleet-enroll` before `fleet-verify-remote` is also §3.3's brick ordering:
# [signing] must follow key existence, and the roster commit that IS the
# genesis cannot come before the key it lists.
assert_ordered "$fleet_agents_skill" 'roundhouse fleet-init' 'roundhouse fleet-enroll'
assert_ordered "$fleet_agents_skill" 'roundhouse fleet-enroll' 'roundhouse fleet-verify-remote'
assert_ordered "$fleet_agents_skill" 'roundhouse fleet-verify-remote' 'roundhouse fleet-seed'
assert_ordered "$fleet_agents_skill" 'roundhouse fleet-seed' \
  'roundhouse fleet-run --fast    # the first convergence'
assert_contains "$fleet_agents_text" '**the first push
refuses without it**'
assert_contains "$fleet_agents_text" 'an unreachable remote is **inconclusive and never
satisfies the gate**'

# The properties that make the supervised surface safe, stated rather than
# implied: a verdict binds to a digest, and none of these verbs publishes.
assert_contains "$fleet_agents_text" '**Every one of them writes into the
working copy and stops**'
assert_contains "$fleet_agents_text" '**A verdict binds to a digest.**'
assert_contains "$fleet_agents_text" 'A stale `pass` fails exactly like an
  absent one'
assert_contains "$fleet_agents_text" 'refused rather than silently
redacted'

# The trust ratchet, stated rather than implied. Each of these is a property a
# reader has to be able to find in the runbook, because getting any of them
# wrong turns a containment story into a fleet outage.
assert_contains "$fleet_agents_text" 'signed by a
key the file already trusted one commit earlier'
assert_contains "$fleet_agents_text" '**no CA, no certificate, no authority key**'
assert_contains "$fleet_agents_text" '**Leaves may not sponsor**'
assert_contains "$fleet_agents_text" '**cleanup metadata and nothing else**'
# The store id is the genesis commit id and is an OUTPUT, never a paste.
assert_contains "$fleet_agents_text" '**genesis commit id**'
assert_contains "$fleet_agents_text" 'It is an *output* of setup'
# Removal freezes at position in history; the KRL is retroactive and total.
assert_contains "$fleet_agents_text" '**Revocation lives in the chain, and position in history decides validity.**'
assert_contains "$fleet_agents_text" '**The KRL is the emergency lever, not the default.**'
assert_contains "$fleet_agents_text" 'freeze at position in
history'
# Checkpoints are tags and the archive is part of the protocol.
assert_contains "$fleet_agents_text" '**A
bookmark does not do this.**'
assert_contains "$fleet_agents_text" '**The archive ref is part of the protocol, not hygiene.**'
# The residuals, named rather than hidden.
assert_contains "$fleet_agents_text" '**Instruction-chain compromise has no technical mitigation.**'
assert_contains "$fleet_agents_text" '**Availability is out of scope.**'

# The conflict posture, and the boundary on agent resolution.
assert_contains "$fleet_agents_text" '**Publication-silent while a conflict is open.**'
assert_contains "$fleet_agents_text" 'Anything the ladder cannot decide on evidence **holds and
  is reported by name**'
# Rollback is the ordinary path, and --now is bound rather than a switch.
assert_contains "$fleet_agents_text" 'Rollback is **not a special path**'
assert_contains "$fleet_agents_text" 'A bypass nobody counts is a
bypass that becomes routine'
# B-1, recorded where a reader will look for it rather than only in the plan.
assert_contains "$fleet_agents_text" '**platform and groups
only**'
# The privilege-broker seam is unchanged by the storage redesign: the U1/U2
# lane is exactly what phase 1 must not touch.
assert_contains "$fleet_agents_text" 'Desired state lives here; root-touching authority lives with the privilege
broker per `docs/specs/2026-08-06-unattended-privileged-updates.md`'
assert_contains "$fleet_agents_text" 'must not change without
cross-checking the sibling spec'


# The per-type state-alignment capability table (spec open item 2).
assert_contains "$fleet_agents_text" '### State-alignment capability per item type'
assert_contains "$fleet_agents_text" 'claude plugin enable\|disable PLUGIN@MARKETPLACE --scope user'
assert_contains "$fleet_agents_text" 'no enable/disable verb — presence only'
assert_contains "$fleet_agents_text" 'hooks.state."HOOK-KEY".enabled'
assert_contains "$fleet_agents_text" 'host-local trust and is never synced'
assert_contains "$fleet_agents_text" 'only *state* falls back to config edits'
# The verbs are stated as VERIFIED against named harness versions, and the
# Codex row no longer claims a plugin enable/disable verb that does not exist.
assert_contains "$fleet_agents_text" 'verified against claude 2.1.222 / codex-cli 0.146.0'
assert_contains "$fleet_agents_text" '`[plugins."PLUGIN@MARKETPLACE"] enabled` key in `~/.codex/config.toml`'
case $fleet_agents_text in
  *'unverified per-harness'*)
    fail "fleet-agents still hedges the capability verbs as unverified" ;;
  *'codex plugin enable'* | *'codex plugin disable'*)
    fail "fleet-agents still claims a codex plugin enable/disable verb" ;;
esac

# One owned scheduler entry per host survives the excision; the prompt it runs
# no longer drives a sync run, and no second entry appears in its place.
fleet_update_skill="$script_dir/../skills/fleet-update/SKILL.md"
fleet_update_text=$(cat "$fleet_update_skill")
assert_contains "$fleet_update_text" 'exactly one owned scheduler
entry per host'
assert_contains "$fleet_update_text" 'Two local runners racing one
plugin cache is the failure this prevents'
assert_contains "$fleet_update_text" 'so a second entry is never
added'
# The one owned entry now runs `fleet-run`, and it ABSORBS the older
# autoupdate entry rather than sitting beside it. A host carrying both is the
# double-runner the singularity rule exists to prevent, so the absorption is
# asserted by name — a doc that merely says "one entry" while the old one is
# still loaded is a doc that reads true and is false.
assert_contains "$fleet_update_text" 'it runs `roundhouse fleet-run`'
assert_contains "$fleet_update_text" '**Absorb, never duplicate**'
assert_contains "$fleet_update_text" 'com.novotnyllc.roundhouse.autoupdate'
assert_contains "$fleet_update_text" 'unload and remove it in the same step that installs the
fleet entry'
assert_contains "$fleet_update_text" 'roundhouse fleet-run --fast'
assert_contains "$fleet_update_text" 'roundhouse fleet-run --full'
# All three platforms, because a scheduler section that only says "launchd"
# leaves two thirds of this fleet with nothing scheduled.
assert_contains "$fleet_update_text" 'com.novotnyllc.roundhouse.fleet.plist'
assert_contains "$fleet_update_text" 'systemd **user** timer pair'
assert_contains "$fleet_update_text" 'per-user** scheduled task'
case $fleet_update_text in
  *'three-phase sync run'*)
    fail "fleet-update still schedules the deleted three-phase sync run"
    ;;
  *'autoupdate.plist'*)
    fail "fleet-update still schedules the superseded autoupdate entry"
    ;;
esac
# The lock's exit codes, as the code actually uses them: an ordinary overlap
# exits 0 and only a STALE lock is 75. The skill used to promise 75 for the
# ordinary case, so anyone alerting on it got a signal that never fires — and
# that compounded the meta-less lock, which reported `ok` while wedging every
# later run.
assert_contains "$fleet_update_text" 'a second run finds the lock
held and exits 0 without acting'
assert_contains "$fleet_update_text" 'Exit 75 is the STALE-lock refusal'
assert_contains "$fleet_update_text" 'whose `meta.json` is missing so its age cannot be read'
assert_contains "$fleet_update_text" 'Unattended runs skip protected/privileged actions'

# fleet-hosts carries the store-credential lifecycle and the restore sequence.
fleet_hosts_skill="$script_dir/../skills/fleet-hosts/SKILL.md"
fleet_hosts_text=$(cat "$fleet_hosts_skill")
assert_contains "$fleet_hosts_text" 'an SSH deploy key generated on the host and
   kept in `~/.ssh`, or a token held by a credential helper'
assert_contains "$fleet_hosts_text" '**Never embed
   the credential in the remote URL**'
assert_contains "$fleet_hosts_text" 'Scope it to the single private
   store repository and reuse it for nothing else'
assert_contains "$fleet_hosts_text" '**Revoke the store credential alongside SSH trust**'
assert_contains "$fleet_hosts_text" '## Restore a host'
assert_contains "$fleet_hosts_text" 'configs plus a shopping list'
assert_contains "$fleet_hosts_text" '**Read first**'
assert_contains "$fleet_hosts_text" 'cannot restore secrets, per-machine auth, or
SSH identity'
for sync_restore_step in \
    '**Enrollment** — run the add-a-host flow above for X' \
    '**Store credentials** — provision X'"'"'s own store credential' \
    '**Materialize file-carried surfaces**' \
    '**Replay manager installs**' \
    '**Per-artifact reauth**'; do
  assert_contains "$fleet_hosts_text" "$sync_restore_step"
done
assert_ordered "$fleet_hosts_skill" '**Enrollment** — run the add-a-host flow' \
  '**Store credentials** — provision X'
assert_ordered "$fleet_hosts_skill" '**Store credentials** — provision X' \
  '**Materialize file-carried surfaces**'
assert_ordered "$fleet_hosts_skill" '**Materialize file-carried surfaces**' \
  '**Replay manager installs**'
assert_ordered "$fleet_hosts_skill" '**Replay manager installs**' \
  '**Per-artifact reauth**'

readiness_skill="$script_dir/../skills/fleet-readiness/SKILL.md"
[ -f "$readiness_skill" ] || fail "fleet-readiness skill is missing"
grep -Fx 'name: fleet-readiness' "$readiness_skill" >/dev/null ||
  fail "fleet-readiness frontmatter name is missing"
jq -e '.skills | index("./skills/fleet-readiness") != null' \
  "$script_dir/../.claude-plugin/plugin.json" >/dev/null ||
  fail "Claude manifest does not expose fleet-readiness"
readiness_text=$(cat "$readiness_skill")
assert_contains "$readiness_text" 'Desired-state readiness is `roundhouse fleet-doctor`, whose contract lives in
`roundhouse:fleet-agents` and is authoritative there'
assert_contains "$readiness_text" 'never duplicate or paraphrase them here'
