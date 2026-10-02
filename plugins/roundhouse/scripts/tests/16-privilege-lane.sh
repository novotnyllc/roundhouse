# Sourced by scripts/test-roundhouse — the local privilege lane: controller
# status/enrollment/plan verbs over every transport, the readiness and doctor
# rows, and the host-local routing fleet-run uses. The helpers' own
# `self-test`/`-SelfTest` cover the root/SYSTEM side; this section covers
# the controller around them with the POSIX helper in fixture mode.
# shellcheck shell=bash

lane_tmp=$tmp/lane
mkdir -p "$lane_tmp/bin" "$lane_tmp/fixture"
# The remote side resolves the installed helper through `roundhouse` on PATH.
cat >"$lane_tmp/bin/roundhouse" <<SH
#!/bin/sh
exec "$cli" "\$@"
SH
chmod +x "$lane_tmp/bin/roundhouse"
# apt stubs the fixture lane executes as its "root" side.
cat >"$lane_tmp/bin/apt-get" <<SH
#!/bin/sh
printf 'apt-get %s\n' "\$*" >>"$lane_tmp/apt.log"
case "\$*" in
  "-q update") [ ! -e "$lane_tmp/apt-update-fail" ] || exit 100 ;;
  *"install curl=8.2.0-1"*) printf '8.2.0-1\n' >"$lane_tmp/state-curl" ;;
esac
exit 0
SH
cat >"$lane_tmp/bin/apt-cache" <<SH
#!/bin/sh
case "\$1 \$2" in
  "policy curl") printf 'curl:\n  Installed: %s\n  Candidate: 8.2.0-1\n' "\$(cat "$lane_tmp/state-curl" 2>/dev/null || printf '8.1.0-1')" ;;
  "policy ") printf 'curl:\n  Installed: 8.1.0-1\n' ;;
  *) exit 100 ;;
esac
SH
cat >"$lane_tmp/bin/dpkg-query" <<SH
#!/bin/sh
case "\$4" in curl) cat "$lane_tmp/state-curl" 2>/dev/null || printf '8.1.0-1' ;; *) exit 1 ;; esac
SH
chmod +x "$lane_tmp/bin/apt-get" "$lane_tmp/bin/apt-cache" "$lane_tmp/bin/dpkg-query"

lane_env() {
  # lane_env COMMAND...: the controller with the fixture lane on a Linux
  # "host" that is this machine.
  PATH="$lane_tmp/bin:$PATH" ROUNDHOUSE_LANE_FIXTURE_ROOT="$lane_tmp/fixture" \
    ROUNDHOUSE_LANE_FIXTURE_BIN="$lane_tmp/bin" ROUNDHOUSE_LANE_FIXTURE_PLATFORM=linux "$@"
}
lane_rc=0

# --- before the one approval ------------------------------------------------
lane_env "$cli" privilege-lane-status test-apt "$lane_tmp/status.json" >/dev/null 2>&1 || lane_rc=$?
[ "$lane_rc" -eq 75 ] || fail "lane status before enrollment exited $lane_rc, expected 75"
jq -e '.schema == "roundhouse.privilege-lane-status" and .state == "needs_one_time_approval" and
  .route == "local" and .transport == "local" and .next_command == "roundhouse privilege-enroll test-apt" and
  (.actions | index("apt.upgrade-package.v1") != null)' "$lane_tmp/status.json" >/dev/null ||
  fail "lane status before enrollment: $(cat "$lane_tmp/status.json")"

lane_env "$cli" privilege-status test-apt "$lane_tmp/readiness.jsonl" >/dev/null 2>&1 || :
"$cli" validate "$lane_tmp/readiness.jsonl" >/dev/null || fail 'lane readiness snapshot failed validation'
jq -e '.kind == "privilege_broker" and .id == "readiness" and .host_id == "test-apt" and
  .data.transport == "local-lane" and .data.lifecycle_status == "needs_one_time_approval" and
  .data.broker_ready == false' "$lane_tmp/readiness.jsonl" >/dev/null ||
  fail "privilege-status did not report the lane: $(cat "$lane_tmp/readiness.jsonl")"

lane_env "$cli" prepare-privilege-enrollment test-apt "$lane_tmp/prep.json" >/dev/null 2>&1 || :
jq -e '.route == "local-lane" and .state == "needs_one_time_approval" and .reason == "one_os_approval_required" and
  .next_command == "roundhouse privilege-enroll test-apt" and .activation_performed == false and
  (.fixed_entrypoints[0].path == "scripts/privilege-lane-posix") and
  (.credential_handling | contains("never_requests_or_relays"))' "$lane_tmp/prep.json" >/dev/null ||
  fail "prepare-privilege-enrollment did not name the one approval: $(cat "$lane_tmp/prep.json")"

# Without a terminal the enrollment never prompts: it names the command.
lane_rc=0
lane_env "$cli" privilege-enroll test-apt >"$lane_tmp/enroll-notty.json" 2>"$lane_tmp/enroll-notty.err" </dev/null || lane_rc=$?
[ "$lane_rc" -eq 75 ] || fail "privilege-enroll without a terminal exited $lane_rc, expected 75"
jq -e '.state == "needs_one_time_approval" and .next_command == "roundhouse privilege-enroll test-apt"' \
  "$lane_tmp/enroll-notty.json" >/dev/null || fail 'privilege-enroll without a terminal did not report the pending approval'
grep -q 'one sudo password prompt' "$lane_tmp/enroll-notty.err" || fail 'privilege-enroll did not explain the one prompt'
[ ! -e "$lane_tmp/fixture/usr/local/libexec/roundhouse-lane/privilege-lane" ] || fail 'privilege-enroll installed without approval'

# The readiness table reports the pending approval without a finding.
lane_env "$cli" fleet-readiness test-apt >"$lane_tmp/readiness.txt" 2>/dev/null || :
grep -Eq '^PENDING  test-apt +privilege-lane +needs_one_time_approval: run `roundhouse privilege-enroll test-apt` once$' \
  "$lane_tmp/readiness.txt" || fail "fleet-readiness did not report the pending lane: $(cat "$lane_tmp/readiness.txt")"
grep -Eq '^FINDING  test-apt +privilege-lane' "$lane_tmp/readiness.txt" && fail 'an unenrolled lane counted as a finding'

# A plan cannot be sealed against a lane that is not ready.
cat >"$lane_tmp/draft.json" <<'JSON'
{"domain":"updates","target":"test-apt","lane":"local","operations":[
  {"type":"semantic-action","kind":"privileged_action","id":"apt.update-metadata.v1","package":"-","version":"-","source":"-"},
  {"type":"semantic-action","kind":"privileged_action","id":"apt.upgrade-package.v1","package":"curl","version":"8.2.0-1","source":"-"}]}
JSON
lane_rc=0
lane_env "$cli" seal-plan "$lane_tmp/draft.json" "$lane_tmp/readiness.jsonl" "$lane_tmp/plan.json" >/dev/null 2>&1 || lane_rc=$?
[ "$lane_rc" -eq 65 ] || fail "seal-plan sealed a lane plan against an unenrolled lane (rc $lane_rc)"

# --- the one approval, through the test hook ----------------------------------
# The hook stands in for `sudo …/privilege-lane-posix enroll`; the helper's
# own self-test covers what that enrollment does on the host.
lane_enroll_hook="ROUNDHOUSE_LANE_FIXTURE_ROOT='$lane_tmp/fixture' ROUNDHOUSE_LANE_FIXTURE_BIN='$lane_tmp/bin' ROUNDHOUSE_LANE_FIXTURE_PLATFORM=linux '$script_dir/privilege-lane-posix' enroll --host-id \"\$1\" --owner \"\$(id -un)\""
lane_rc=0
ROUNDHOUSE_LANE_ENROLL_COMMAND="$lane_enroll_hook" lane_env "$cli" privilege-enroll test-apt >"$lane_tmp/enroll.json" 2>"$lane_tmp/enroll.err" </dev/null || lane_rc=$?
[ "$lane_rc" -eq 0 ] || fail "privilege-enroll through the hook exited $lane_rc: $(cat "$lane_tmp/enroll.err")"
jq -e '.state == "enrolled" and .reason == "one_time_approval_complete" and (.canary | contains("probe-completed")) and
  .next_command == "-"' "$lane_tmp/enroll.json" >/dev/null || fail "privilege-enroll report: $(cat "$lane_tmp/enroll.json")"
grep -Fq "$(id -un) ALL=(root) NOPASSWD:NOSETENV: /usr/local/libexec/roundhouse-lane/privilege-lane dispatch" \
  "$lane_tmp/fixture/etc/sudoers.d/roundhouse-lane" || fail 'the enrollment did not install the exact sudoers grant'

lane_env "$cli" privilege-lane-status test-apt "$lane_tmp/status.json" >/dev/null || fail 'lane status after enrollment'
jq -e '.state == "ready" and .host_id == "test-apt" and (.lane_version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and
  (.lane_sha256 | test("^[0-9a-f]{64}$"))' "$lane_tmp/status.json" >/dev/null || fail "lane status ready: $(cat "$lane_tmp/status.json")"
lane_env "$cli" fleet-readiness test-apt >"$lane_tmp/readiness.txt" 2>/dev/null || :
grep -Eq '^ok       test-apt +privilege-lane +enrolled, lane [0-9.]+$' "$lane_tmp/readiness.txt" ||
  fail "fleet-readiness did not report the enrolled lane: $(cat "$lane_tmp/readiness.txt")"
lane_env "$cli" prepare-privilege-enrollment test-apt "$lane_tmp/prep.json" >/dev/null 2>&1 || :
jq -e '.state == "ready" and .reason == "lane_enrolled" and .next_command == "-"' "$lane_tmp/prep.json" >/dev/null ||
  fail 'prepare-privilege-enrollment did not report the enrolled lane'

# --- the sealed lane plan ------------------------------------------------------
lane_env "$cli" privilege-status test-apt "$lane_tmp/readiness.jsonl" >/dev/null 2>&1 || fail 'privilege-status after enrollment'
lane_snapshot_id=$(jq -r '.snapshot_id' "$lane_tmp/readiness.jsonl")
{
  cat "$lane_tmp/readiness.jsonl"
  jq -cn --arg s "$lane_snapshot_id" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    {schema:"roundhouse.inventory",schema_version:1,snapshot_id:$s,host_id:"test-apt",kind:"package",id:"apt:curl",
     observed_at:$at,status:"present",confidence:"high",
     data:{manager:"apt",name:"curl",installed_version:"8.1.0-1",candidate_version:"8.2.0-1",update_available:true},
     evidence:[],errors:[]}'
} >"$lane_tmp/snapshot.jsonl"
"$cli" validate "$lane_tmp/snapshot.jsonl" >/dev/null || fail 'lane plan snapshot failed validation'
lane_env "$cli" seal-plan "$lane_tmp/draft.json" "$lane_tmp/snapshot.jsonl" "$lane_tmp/plan.json" >/dev/null ||
  fail 'seal-plan refused a valid lane draft'
chmod 600 "$lane_tmp/plan.json"
jq -e '.schema == "roundhouse.plan" and .schema_version == 5 and .lane == "local" and
  (.plan_id | test("^plan-[0-9a-f]{16}$")) and (.operations | length == 2) and
  ([.operations[].request_id] | all(test("^request-[0-9a-f]{32}$"))) and
  (.operations[1].package == "curl") and (.operations[1].version == "8.2.0-1") and
  (.precondition.value | test("^[0-9a-f]{64}$"))' "$lane_tmp/plan.json" >/dev/null ||
  fail "sealed lane plan shape: $(cat "$lane_tmp/plan.json")"
# Nothing argv-shaped survives sealing.
jq -e '[.. | strings] | any(test("sudo|apt-get|/bin/"))' "$lane_tmp/plan.json" >/dev/null && fail 'a lane plan carried argv'
lane_plan_id=$(jq -r '.plan_id' "$lane_tmp/plan.json")

lane_env "$cli" verify-privilege-plan "$lane_tmp/plan.json" "$lane_tmp/snapshot.jsonl" >/dev/null ||
  fail 'verify-privilege-plan refused the sealed lane plan'
# A drifted candidate version is a refusal, never a resubmission.
jq -c 'if .kind == "package" then .data.candidate_version = "8.3.0-1" else . end' "$lane_tmp/snapshot.jsonl" >"$lane_tmp/drifted.jsonl"
lane_rc=0
lane_env "$cli" verify-privilege-plan "$lane_tmp/plan.json" "$lane_tmp/drifted.jsonl" >/dev/null 2>&1 || lane_rc=$?
[ "$lane_rc" -eq 65 ] || fail "verify-privilege-plan accepted a drifted candidate (rc $lane_rc)"
# A tampered plan fails its own integrity check.
jq '.operations[1].version = "9.9.9"' "$lane_tmp/plan.json" >"$lane_tmp/tampered.json"
chmod 600 "$lane_tmp/tampered.json"
lane_rc=0
lane_env "$cli" verify-privilege-plan "$lane_tmp/tampered.json" "$lane_tmp/snapshot.jsonl" >/dev/null 2>&1 || lane_rc=$?
[ "$lane_rc" -eq 65 ] || fail "verify-privilege-plan accepted a tampered lane plan (rc $lane_rc)"

# Submission: one lane request per operation, in order, each digest-bound
# to the plan; the inventory records say what happened.
: >"$lane_tmp/apt.log"
lane_rc=0
lane_env "$cli" submit-privilege-plan "$lane_tmp/plan.json" "$lane_plan_id" "$lane_tmp/apply.jsonl" >/dev/null 2>"$lane_tmp/apply.err" || lane_rc=$?
[ "$lane_rc" -eq 0 ] || fail "submit-privilege-plan exited $lane_rc: $(cat "$lane_tmp/apply.err")"
"$cli" validate "$lane_tmp/apply.jsonl" >/dev/null || fail 'lane apply records failed validation'
[ "$(jq -s 'length' "$lane_tmp/apply.jsonl")" -eq 2 ] || fail 'lane apply did not record both operations'
jq -e -s 'all(.[]; .kind == "operation" and .data.transport == "local-lane" and .data.operation_status == "completed" and
  .data.state == "completed" and (.data.request_id | test("^request-[0-9a-f]{32}$")))' "$lane_tmp/apply.jsonl" >/dev/null ||
  fail "lane apply records: $(cat "$lane_tmp/apply.jsonl")"
grep -Fqx 'apt-get -q update' "$lane_tmp/apt.log" && grep -Fqx 'apt-get -q -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold --no-remove --only-upgrade install curl=8.2.0-1' "$lane_tmp/apt.log" ||
  fail "the lane did not run the fixed apt commands: $(cat "$lane_tmp/apt.log")"
jq -r -s '.[1].data.result_record[]' "$lane_tmp/apply.jsonl" | grep -Fqx "plan-id|$lane_plan_id" || fail 'the lane result is not bound to the plan id'
jq -r -s '.[1].data.result_record[]' "$lane_tmp/apply.jsonl" | grep -Fqx 'operation-index|1' || fail 'the lane result is not bound to the operation index'
jq -r -s '.[1].data.result_record[]' "$lane_tmp/apply.jsonl" | grep -Fqx "plan-sha256|$(jq -r '.plan_digest.value' "$lane_tmp/plan.json")" ||
  fail 'the lane result is not bound to the plan digest'

# Apply rechecks the whole sealed precondition right before submitting: a
# candidate that moved after sealing is a refusal, never a stale submission.
cat >"$lane_tmp/drift-draft.json" <<'JSON'
{"domain":"updates","target":"test-apt","lane":"local","operations":[
  {"type":"semantic-action","kind":"privileged_action","id":"apt.upgrade-package.v1","package":"curl","version":"8.2.0-1","source":"-"}]}
JSON
printf '8.1.0-1\n' >"$lane_tmp/state-curl"
lane_env "$cli" privilege-status test-apt "$lane_tmp/drift-readiness.jsonl" >/dev/null 2>&1 || fail 'privilege-status for the drift plan'
{
  cat "$lane_tmp/drift-readiness.jsonl"
  jq -cn --arg s "$(jq -r '.snapshot_id' "$lane_tmp/drift-readiness.jsonl")" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    {schema:"roundhouse.inventory",schema_version:1,snapshot_id:$s,host_id:"test-apt",kind:"package",id:"apt:curl",
     observed_at:$at,status:"present",confidence:"high",
     data:{manager:"apt",name:"curl",installed_version:"8.0.0-1",candidate_version:"8.2.0-1",update_available:true},
     evidence:[],errors:[]}'
} >"$lane_tmp/drift-snapshot.jsonl"
lane_env "$cli" seal-plan "$lane_tmp/drift-draft.json" "$lane_tmp/drift-snapshot.jsonl" "$lane_tmp/drift-plan.json" >/dev/null || fail 'seal-plan for the drift plan'
chmod 600 "$lane_tmp/drift-plan.json"
: >"$lane_tmp/apt.log"
lane_rc=0
lane_env "$cli" submit-privilege-plan "$lane_tmp/drift-plan.json" "$(jq -r '.plan_id' "$lane_tmp/drift-plan.json")" "$lane_tmp/drift-apply.jsonl" >/dev/null 2>"$lane_tmp/drift.err" || lane_rc=$?
[ "$lane_rc" -eq 65 ] && grep -q 'preconditions drifted' "$lane_tmp/drift.err" || fail "apply submitted despite a package drift (rc $lane_rc): $(cat "$lane_tmp/drift.err")"
[ ! -s "$lane_tmp/apt.log" ] || fail 'a drifted plan reached apt-get'

# Lookup reads the published result for an operation without resubmitting.
: >"$lane_tmp/apt.log"
lane_env "$cli" lookup-privilege-result "$lane_tmp/plan.json" 1 "$lane_tmp/lookup.result" >/dev/null ||
  fail 'lookup-privilege-result failed for a completed lane operation'
grep -Fqx 'reason|package_upgraded' "$lane_tmp/lookup.result" || fail "lookup result: $(cat "$lane_tmp/lookup.result")"
[ ! -s "$lane_tmp/apt.log" ] || fail 'lookup-privilege-result executed something'
# The plan's request ids were consumed: a second submission is a replay and
# never executes again.
lane_rc=0
lane_env "$cli" submit-privilege-plan "$lane_tmp/plan.json" "$lane_plan_id" "$lane_tmp/apply-again.jsonl" >/dev/null 2>&1 || lane_rc=$?
[ "$lane_rc" -eq 65 ] || fail "a resubmitted lane plan exited $lane_rc, expected 65"
[ ! -s "$lane_tmp/apt.log" ] || fail 'a resubmitted lane plan executed something'
# A request id the lane never saw cannot be looked up (the plan's digest no
# longer matches, which is the integrity refusal, never a guess).
jq '.operations[0].request_id = "request-00000000000000000000000000000000"' "$lane_tmp/plan.json" >"$lane_tmp/unknown.json"
chmod 600 "$lane_tmp/unknown.json"
lane_rc=0
lane_env "$cli" lookup-privilege-result "$lane_tmp/unknown.json" 0 "$lane_tmp/unknown.result" >/dev/null 2>&1 || lane_rc=$?
[ "$lane_rc" -eq 65 ] || fail "lookup of a tampered plan exited $lane_rc, expected 65"
# The controller's catalog and the helpers' catalogs agree, per platform.
for lane_platform in linux wsl macos; do
  while IFS= read -r lane_action; do
    "$script_dir/privilege-lane-posix" actions "$lane_platform" | grep -Fqx "$lane_action" ||
      fail "the controller advertises $lane_action on $lane_platform but the POSIX helper does not implement it"
  done <<EOF
$(ROUNDHOUSE_LIB_ONLY=1 . "$cli"; lane_actions_for_platform "$lane_platform")
EOF
done
# Payload-backed actions are implemented by the helpers but not sealable yet.
for lane_platform in linux macos windows; do
  if (ROUNDHOUSE_LIB_ONLY=1 . "$cli"; lane_actions_for_platform "$lane_platform") | grep -Eq 'macos.install-signed-pkg|lane.self-upgrade'; then
    fail "the controller advertises a payload-backed action the sealed format cannot carry"
  fi
done
lane_windows_actions=$(sed -n 's/^\$script:Actions = \[string\[\]\]@(\(.*\)$/\1/p' "$script_dir/privilege-lane-windows.ps1" |
  tr -d '")' | tr ',' '\n' | sed 's/^ *//' | grep . ; sed -n '/^\$script:Actions = /,/)$/p' "$script_dir/privilege-lane-windows.ps1" | sed 1d | tr -d '")' | tr ',' '\n' | sed 's/^ *//' | grep .)
while IFS= read -r lane_action; do
  printf '%s\n' "$lane_windows_actions" | grep -Fqx "$lane_action" ||
    fail "the controller advertises $lane_action on windows but the Windows helper does not implement it"
done <<EOF
$(ROUNDHOUSE_LIB_ONLY=1 . "$cli"; lane_actions_for_platform windows)
EOF

# --- host-local routing used by fleet-run --------------------------------------
# The fast pass installs apt packages through the lane; before enrollment
# the same call holds (75) with the one-approval alert text.
(
  ROUNDHOUSE_LIB_ONLY=1 . "$cli"
  : >"$lane_tmp/apt.log"
  fleet_host_name() { printf 'test-apt\n'; }
  lane_env fleet_install_package apt curl false 8.2.0-1 || fail "fleet_install_package apt through the lane failed"
  grep -Fqx 'apt-get -q -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold --no-install-recommends install curl=8.2.0-1' "$lane_tmp/apt.log" ||
    fail "fleet_install_package did not route apt through the lane: $(cat "$lane_tmp/apt.log")"
  # Every host-local mutation is a sealed plan: the lane's journal shows a
  # sealed plan id, never the ad-hoc fleet-run token.
  grep -q '|request|request-[0-9a-f]*|apt.install-package-version.v1|' "$lane_tmp/fixture/var/lib/roundhouse-lane/journal/events.log" ||
    fail 'host-local install was not journaled'
  lane_last_result=$(ls -t "$lane_tmp/fixture/var/lib/roundhouse-lane/results"/*.result | head -n 1)
  grep -Eq '^plan-id\|plan-[0-9a-f]{16}$' "$lane_last_result" || fail "host-local install did not ride a sealed plan: $(grep '^plan-id' "$lane_last_result")"
  grep -Eq '^plan-sha256\|[0-9a-f]{64}$' "$lane_last_result" || fail 'host-local install carried no plan digest'
  # An unpinned install carries the `-` sentinel, never an empty version.
  : >"$lane_tmp/apt.log"
  lane_env fleet_install_package apt curl false || fail "unpinned fleet_install_package apt failed"
  grep -Fqx 'apt-get -q -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold --no-install-recommends install curl' "$lane_tmp/apt.log" ||
    fail "unpinned install did not reach apt-get without a version: $(cat "$lane_tmp/apt.log")"
  # The full-pass apt arm: metadata refresh and upgrade, both sealed.
  : >"$lane_tmp/apt.log"
  printf '8.1.0-1\n' >"$lane_tmp/state-curl"
  lane_env lane_fleet_run_apt "$tmp/store" test-apt curl curl "" >/dev/null 2>&1 || :
  grep -Fqx 'apt-get -q update' "$lane_tmp/apt.log" || fail "full-pass apt refresh did not run through the lane: $(cat "$lane_tmp/apt.log")"
  grep -q 'only-upgrade install curl=8.2.0-1' "$lane_tmp/apt.log" || fail "full-pass apt upgrade did not run through the lane: $(cat "$lane_tmp/apt.log")"
  [ "$(grep -c '|apt.update-metadata.v1|' "$lane_tmp/fixture/var/lib/roundhouse-lane/journal/events.log")" -ge 1 ] || fail 'refresh not journaled'
  lane_fleet_apt_refreshed=; lane_fleet_apt_alerted=
  # A failed metadata refresh holds the pass's apt upgrades: nothing is
  # upgraded from a stale cache.
  : >"$lane_tmp/apt.log"; : >"$lane_tmp/apt-update-fail"; printf '8.1.0-1\n' >"$lane_tmp/state-curl"
  lane_apt_hold=$(lane_env lane_fleet_run_apt "$tmp/store" test-apt curl curl "" 2>/dev/null) || :
  rm -f "$lane_tmp/apt-update-fail"
  printf '%s\n' "$lane_apt_hold" | grep -q 'apt metadata refresh did not complete' || fail "failed refresh did not hold: $lane_apt_hold"
  grep -q 'only-upgrade' "$lane_tmp/apt.log" && fail 'an upgrade ran after a failed metadata refresh'
  lane_fleet_apt_refreshed=; lane_fleet_apt_alerted=; lane_fleet_apt_refresh_failed=
  # A host-local plan whose version is not the candidate is refused at
  # sealing, and nothing reaches apt-get.
  : >"$lane_tmp/apt.log"
  lane_rc=0
  lane_env lane_host_apply test-apt "[$(lane_operation_json apt.upgrade-package.v1 curl 9.9.9)]" >/dev/null 2>"$lane_tmp/host-apply.err" || lane_rc=$?
  [ "$lane_rc" -eq 65 ] || fail "host-local apply with a stale version exited $lane_rc, expected 65"
  [ ! -s "$lane_tmp/apt.log" ] || fail 'a refused host-local plan reached apt-get'
  lane_env lane_package_hold_detail packages.curl test-apt | grep -q 'no package manager on this host can provide' ||
    fail 'an enrolled lane still blamed the package manager'
  lane_env fleet_doctor_lane_row | grep -Eq '^ok       privilege-lane +enrolled, lane [0-9.]+ [0-9a-f]{12}$' ||
    fail 'fleet-doctor did not report the enrolled lane'
  mv "$lane_tmp/fixture" "$lane_tmp/fixture.enrolled"
  mkdir -p "$lane_tmp/fixture"
  lane_rc=0
  lane_env fleet_install_package apt curl false >/dev/null 2>&1 || lane_rc=$?
  [ "$lane_rc" -eq 75 ] || fail "fleet_install_package apt without a lane returned $lane_rc, expected 75"
  lane_env lane_package_hold_detail packages.curl test-apt | grep -q 'run `roundhouse privilege-enroll test-apt` once' ||
    fail 'the hold text did not name the one-time approval'
  lane_env fleet_doctor_lane_row | grep -Eq '^ok       privilege-lane +not enrolled' ||
    fail 'fleet-doctor did not report the unenrolled lane as pending'
  rm -rf "$lane_tmp/fixture"
  mv "$lane_tmp/fixture.enrolled" "$lane_tmp/fixture"
) || exit 1

# --- SSH transport ------------------------------------------------------------
# test-ssh reaches `fake-host`; the stub runs the remote command locally, so
# the same fixture lane answers through `roundhouse privilege-lane-path`.
: >"$lane_tmp/ssh.log"
SSH_COMMAND_LOG="$lane_tmp/ssh.log" lane_env "$cli" privilege-lane-status test-ssh "$lane_tmp/ssh-status.json" >/dev/null 2>&1 || :
jq -e '.transport == "ssh fake-host" and (.state | IN("ready","drifted"))' "$lane_tmp/ssh-status.json" >/dev/null ||
  fail "lane status over ssh: $(cat "$lane_tmp/ssh-status.json")"
grep -q 'fake-host' "$lane_tmp/ssh.log" && grep -q 'privilege-lane-path' "$lane_tmp/ssh.log" ||
  fail 'the ssh transport did not resolve the remote helper through roundhouse'
grep -Eq 'RequestTTY=no' "$lane_tmp/ssh.log" || fail 'a lane status probe requested a TTY'

# --- the Windows sibling over WSL interop --------------------------------------
# A native-Windows machine is reached through its WSL sibling; the SYSTEM-side
# helper answers through pwsh. A fake pwsh.exe stands in for the Windows side
# and the drive root for /mnt/c.
lane_interop_root=$lane_tmp/interop-root
mkdir -p "$lane_interop_root/ProgramData/Roundhouse-Lane" "$lane_interop_root/Windows/System32"
cat >"$lane_tmp/pwsh.exe" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"${LANE_PWSH_LOG:?}"
case "$*" in
  *-Status*) cat "${LANE_PWSH_STATUS:?}" ;;
  *-Request*) cat "${LANE_PWSH_RESULT:?}" ;;
  *-Candidate*) printf '%s\n' 'lane-candidate|1' 'package|OpenJS.NodeJS' 'installed|26.0.0' "candidate|${LANE_PWSH_CANDIDATE:-26.1.0}" 'end-candidate|' ;;
  *-Enroll*) cat "${LANE_PWSH_ENROLL:?}" ;;
  *) exit 64 ;;
esac
SH
chmod +x "$lane_tmp/pwsh.exe"
cat >"$lane_interop_root/Windows/System32/cmd.exe" <<'SH'
#!/bin/sh
printf 'C:\\Users\\fixture\r\n'
SH
chmod +x "$lane_interop_root/Windows/System32/cmd.exe"
jq '.machines["test-wsl"] = {platform:"wsl",transport:"ssh",ssh_alias:"fake-host",package_managers:["apt"],physical_host:"iris"} |
    .machines["test-windows"].wsl_interop_via = "test-wsl" | .machines["test-windows"].physical_host = "iris"' \
  "$tmp/config.json" >"$lane_tmp/config.json"
chmod 600 "$lane_tmp/config.json"
printf '%s\n' 'lane-status|1' 'state|ready' 'platform|windows' 'host-id|test-windows' 'owner-sid|S-1-12-1-1-2-3-4' \
  'owner-name|AzureAD/owner' 'lane-version|9.9.9' 'lane-sha256|0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef' \
  'plugin-root|C:\Users\fixture\.claude\plugins\cache\novotnyllc\roundhouse' 'interop-token|limited' 'detail|-' 'next-command|-' 'end-status|' \
  >"$lane_tmp/pwsh-status"
printf '%s\n' 'lane-result|1' 'request-id|request-0123456789abcdef0123456789abcdef' 'host-id|test-windows' 'plan-id|fleet-run' \
  'plan-sha256|-' 'operation-index|-' 'action-id|winget.upgrade-machine-package.v1' 'package|OpenJS.NodeJS' 'version|26.1.0' \
  'state|completed' 'reason|package_upgraded' 'native-exit|0' 'pre-state-sha256|-' 'post-state-sha256|-' 'started-at|1' \
  'finished-at|2' 'lane-version|9.9.9' 'lane-sha256|0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef' \
  'request-sha256|-' 'end-result|' 'result-sha256|-' >"$lane_tmp/pwsh-result"
printf '%s\n' 'lane-enrollment|1' 'state|enrolled' 'reason|one_time_approval_complete' 'platform|windows' 'host-id|test-windows' \
  'owner-sid|S-1-12-1-1-2-3-4' 'lane-version|9.9.9' 'lane-sha256|0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef' \
  'plugin-root|-' 'canary|task-registered,probe-completed' 'end-enrollment|' >"$lane_tmp/pwsh-enroll"
lane_interop() {
  ROUNDHOUSE_CONFIG="$lane_tmp/config.json" ROUNDHOUSE_INTEROP_ROOT="$lane_interop_root" \
    ROUNDHOUSE_INTEROP_PWSH="$lane_tmp/pwsh.exe" LANE_PWSH_LOG="$lane_tmp/pwsh.log" \
    LANE_PWSH_STATUS="$lane_tmp/pwsh-status" LANE_PWSH_RESULT="$lane_tmp/pwsh-result" \
    LANE_PWSH_ENROLL="$lane_tmp/pwsh-enroll" PATH="$lane_tmp/bin:$PATH" "$@"
}
: >"$lane_tmp/pwsh.log"
# Not yet enrolled: the WSL side answers without touching pwsh at all.
lane_rc=0
lane_interop "$cli" privilege-lane-status test-windows "$lane_tmp/win-status.json" >/dev/null 2>&1 || lane_rc=$?
[ "$lane_rc" -eq 75 ] || fail "windows lane status before enrollment exited $lane_rc"
jq -e '.state == "needs_one_time_approval" and .transport == "interop fake-host" and .platform == "windows"' \
  "$lane_tmp/win-status.json" >/dev/null || fail "windows lane status: $(cat "$lane_tmp/win-status.json")"
[ ! -s "$lane_tmp/pwsh.log" ] || fail 'the controller ran pwsh for an unenrolled Windows lane'
lane_interop "$cli" fleet-readiness test-windows >"$lane_tmp/win-readiness.txt" 2>/dev/null || :
grep -Eq '^PENDING  test-windows +privilege-lane +needs_one_time_approval' "$lane_tmp/win-readiness.txt" ||
  fail "fleet-readiness did not report the pending Windows lane: $(cat "$lane_tmp/win-readiness.txt")"
# Enrollment through the sibling: the user-side helper is located in the
# Windows plugin cache at the controller's version and started with
# -Enroll; it raises the UAC prompt itself.
lane_version=$(jq -r '.version' "$script_dir/../.codex-plugin/plugin.json")
mkdir -p "$lane_interop_root/Users/fixture/.claude/plugins/cache/novotnyllc/roundhouse/$lane_version/scripts"
: >"$lane_interop_root/Users/fixture/.claude/plugins/cache/novotnyllc/roundhouse/$lane_version/scripts/privilege-lane-windows.ps1"
lane_rc=0
lane_interop "$cli" privilege-enroll test-windows >"$lane_tmp/win-enroll.json" 2>"$lane_tmp/win-enroll.err" </dev/null || lane_rc=$?
[ "$lane_rc" -eq 0 ] || fail "windows privilege-enroll exited $lane_rc: $(cat "$lane_tmp/win-enroll.err")"
jq -e '.state == "enrolled" and .lane_version == "9.9.9"' "$lane_tmp/win-enroll.json" >/dev/null ||
  fail "windows enrollment report: $(cat "$lane_tmp/win-enroll.json")"
grep -q -- "-File C:.Users.fixture..claude.plugins.cache.novotnyllc.roundhouse.$lane_version.scripts.privilege-lane-windows.ps1 -Enroll -HostId test-windows" \
  "$lane_tmp/pwsh.log" || fail "windows enrollment command: $(cat "$lane_tmp/pwsh.log")"
grep -q 'S4U\|RunAs\|-Credential' "$lane_tmp/pwsh.log" && fail 'the controller passed a credential or S4U argument'
# Enrolled: status and requests go through the SYSTEM-owned copy.
: >"$lane_interop_root/ProgramData/Roundhouse-Lane/privilege-lane-windows.ps1"
: >"$lane_tmp/pwsh.log"
lane_interop "$cli" privilege-lane-status test-windows "$lane_tmp/win-status.json" >/dev/null ||
  fail 'windows lane status after enrollment'
jq -e '.state == "ready" and .owner == "S-1-12-1-1-2-3-4" and .interop_token == "limited" and .lane_version == "9.9.9"' \
  "$lane_tmp/win-status.json" >/dev/null || fail "windows lane status after enrollment: $(cat "$lane_tmp/win-status.json")"
grep -q -- '-File C:\\ProgramData\\Roundhouse-Lane\\privilege-lane-windows.ps1 -Status' "$lane_tmp/pwsh.log" ||
  fail "windows status command: $(cat "$lane_tmp/pwsh.log")"
lane_interop "$cli" privilege-status test-windows "$lane_tmp/win-readiness.jsonl" >/dev/null || fail 'windows privilege-status'
"$cli" validate "$lane_tmp/win-readiness.jsonl" >/dev/null || fail 'windows lane readiness failed validation'
{
  cat "$lane_tmp/win-readiness.jsonl"
  jq -cn --arg s "$(jq -r '.snapshot_id' "$lane_tmp/win-readiness.jsonl")" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    {schema:"roundhouse.inventory",schema_version:1,snapshot_id:$s,host_id:"test-windows",kind:"package",id:"winget:OpenJS.NodeJS",
     observed_at:$at,status:"present",confidence:"high",
     data:{manager:"winget",name:"OpenJS.NodeJS",installed_version:"26.0.0",candidate_version:"26.1.0",update_available:true},
     evidence:[],errors:[]}'
} >"$lane_tmp/win-snapshot.jsonl"
cat >"$lane_tmp/win-draft.json" <<'JSON'
{"domain":"updates","target":"test-windows","lane":"local","operations":[
  {"type":"semantic-action","kind":"privileged_action","id":"winget.upgrade-machine-package.v1","package":"OpenJS.NodeJS","version":"26.1.0","source":"winget"}]}
JSON
lane_interop "$cli" seal-plan "$lane_tmp/win-draft.json" "$lane_tmp/win-snapshot.jsonl" "$lane_tmp/win-plan.json" >/dev/null ||
  fail 'seal-plan refused the Windows lane draft'
chmod 600 "$lane_tmp/win-plan.json"
# A user-scope-only action never seals for the SYSTEM lane: the catalog is machine scope.
jq '.operations[0].id = "winget.upgrade-user-package.v1"' "$lane_tmp/win-draft.json" >"$lane_tmp/win-bad-draft.json"
lane_rc=0
lane_interop "$cli" seal-plan "$lane_tmp/win-bad-draft.json" "$lane_tmp/win-snapshot.jsonl" "$lane_tmp/win-bad-plan.json" >/dev/null 2>&1 || lane_rc=$?
[ "$lane_rc" -eq 64 ] || fail "seal-plan accepted an action outside the Windows lane catalog (rc $lane_rc)"
: >"$lane_tmp/pwsh.log"
lane_interop "$cli" submit-privilege-plan "$lane_tmp/win-plan.json" "$(jq -r '.plan_id' "$lane_tmp/win-plan.json")" \
  "$lane_tmp/win-apply.jsonl" >/dev/null 2>"$lane_tmp/win-apply.err" || fail "windows submit: $(cat "$lane_tmp/win-apply.err")"
grep -q -- "-Request -Action winget.upgrade-machine-package.v1 -Package OpenJS.NodeJS -Version 26.1.0 -Source winget -PayloadSha256 - -PlanId $(jq -r '.plan_id' "$lane_tmp/win-plan.json")" \
  "$lane_tmp/pwsh.log" || fail "windows request command: $(cat "$lane_tmp/pwsh.log")"
jq -e -s '.[0].data.operation_status == "completed" and .[0].data.transport == "local-lane"' "$lane_tmp/win-apply.jsonl" >/dev/null ||
  fail "windows apply records: $(cat "$lane_tmp/win-apply.jsonl")"
# The Windows candidate moved after sealing: apply refuses before any request.
lane_interop "$cli" seal-plan "$lane_tmp/win-draft.json" "$lane_tmp/win-snapshot.jsonl" "$lane_tmp/win-drift-plan.json" >/dev/null ||
  fail 'seal-plan for the Windows drift plan'
chmod 600 "$lane_tmp/win-drift-plan.json"
: >"$lane_tmp/pwsh.log"
lane_rc=0
LANE_PWSH_CANDIDATE=26.2.0 lane_interop "$cli" submit-privilege-plan "$lane_tmp/win-drift-plan.json" \
  "$(jq -r '.plan_id' "$lane_tmp/win-drift-plan.json")" "$lane_tmp/win-drift-apply.jsonl" >/dev/null 2>"$lane_tmp/win-drift.err" || lane_rc=$?
[ "$lane_rc" -eq 65 ] && grep -q 'preconditions drifted' "$lane_tmp/win-drift.err" || fail "windows apply submitted despite a candidate drift (rc $lane_rc)"
grep -q -- '-Request' "$lane_tmp/pwsh.log" && fail 'a drifted Windows plan reached the SYSTEM side'
# No sibling means no session: readiness says so and nothing is attempted.
jq 'del(.machines["test-windows"].wsl_interop_via)' "$lane_tmp/config.json" >"$lane_tmp/config-nosibling.json"
chmod 600 "$lane_tmp/config-nosibling.json"
lane_rc=0
ROUNDHOUSE_CONFIG="$lane_tmp/config-nosibling.json" "$cli" privilege-lane-status test-windows "$lane_tmp/win-status.json" >/dev/null 2>&1 || lane_rc=$?
[ "$lane_rc" -eq 75 ] && jq -e '.state == "user_session_unavailable"' "$lane_tmp/win-status.json" >/dev/null ||
  fail "a Windows host without a WSL sibling did not report user_session_unavailable: $(cat "$lane_tmp/win-status.json")"
ROUNDHOUSE_CONFIG="$lane_tmp/config-nosibling.json" "$cli" prepare-privilege-enrollment test-windows "$lane_tmp/win-prep.json" >/dev/null 2>&1 || :
jq -e '.state == "user_session_unavailable" and .next_command == "-" and (.next_action | contains("user_session"))' "$lane_tmp/win-prep.json" >/dev/null ||
  fail "prepare-privilege-enrollment rewrote user_session_unavailable: $(cat "$lane_tmp/win-prep.json")"

# --- configuration -------------------------------------------------------------
# A machine may opt out; a legacy route still wins; anything else is rejected.
jq '.machines["test-apt"].privilege_lane = "disabled"' "$tmp/config.json" >"$lane_tmp/config-disabled.json"
chmod 600 "$lane_tmp/config-disabled.json"
ROUNDHOUSE_CONFIG="$lane_tmp/config-disabled.json" "$cli" validate-config >/dev/null || fail 'privilege_lane: disabled was rejected'
lane_rc=0
ROUNDHOUSE_CONFIG="$lane_tmp/config-disabled.json" "$cli" privilege-lane-status test-apt "$lane_tmp/status.json" >/dev/null 2>&1 || lane_rc=$?
[ "$lane_rc" -eq 75 ] && jq -e '.state == "disabled"' "$lane_tmp/status.json" >/dev/null || fail 'a disabled lane was not reported as disabled'
jq '.machines["test-apt"].privilege_lane = "sometimes"' "$tmp/config.json" >"$lane_tmp/config-bad.json"
chmod 600 "$lane_tmp/config-bad.json"
if ROUNDHOUSE_CONFIG="$lane_tmp/config-bad.json" "$cli" validate-config >/dev/null 2>&1; then
  fail 'an invalid privilege_lane value was accepted'
fi
lane_rc=0
ROUNDHOUSE_CONFIG="$lane_tmp/config-disabled.json" "$cli" privilege-enroll test-apt >/dev/null 2>&1 </dev/null || lane_rc=$?
[ "$lane_rc" -eq 69 ] || fail "privilege-enroll on a disabled lane exited $lane_rc, expected 69"
# The legacy route keeps its own path: no lane status, no lane enrollment.
jq '.machines["test-apt"].privilege_broker = {automation_transport:{mode:"posix-ssh",host:"linux.example.invalid",port:22,
  request_user:"roundhouse",pinned_host_key_fingerprint:"SHA256:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",management_networks:["192.0.2.0/24"]}}' \
  "$tmp/config.json" >"$lane_tmp/config-legacy.json"
chmod 600 "$lane_tmp/config-legacy.json"
lane_rc=0
ROUNDHOUSE_CONFIG="$lane_tmp/config-legacy.json" "$cli" privilege-enroll test-apt >/dev/null 2>&1 </dev/null || lane_rc=$?
[ "$lane_rc" -eq 69 ] || fail "privilege-enroll with a legacy route exited $lane_rc, expected 69"

# --- no ceremony anywhere in the user-facing text ----------------------------------
for lane_skill in fleet-hosts fleet-readiness fleet-update fleet-auth; do
  lane_text=$(cat "$script_dir/../skills/$lane_skill/SKILL.md")
  assert_contains "$lane_text" 'privilege-enroll'
  case $lane_text in
    *'certify-ssh-node signs'*|*'enroll-windows-sftp.ps1'*|*'owner ceremony'*)
      fail "$lane_skill still tells the user to perform a ceremony" ;;
  esac
done
assert_contains "$(cat "$script_dir/../skills/fleet-update/SKILL.md")" 'needs_one_time_approval'
assert_contains "$(cat "$script_dir/../skills/fleet-readiness/SKILL.md")" 'user_session_unavailable'
rm -rf "$lane_tmp"
printf 'section 16 ok: privilege lane\n'
