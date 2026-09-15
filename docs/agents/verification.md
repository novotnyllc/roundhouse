# Verification

`.github/workflows/validate.yml` runs `posix` (ubuntu-latest and
macos-latest), `scoped` (one runner per `ROUNDHOUSE_TEST_SCOPE` suite per
POSIX platform, fanned out from the `scope-matrix` job) and `windows`
(windows-latest). Reproduce them locally before pushing plugin changes.

## POSIX gates

1. **Syntax** — `bash -n` on every shipped Bash script:

   ```sh
   for s in roundhouse certify-ssh-node collect-posix enroll-privilege-posix \
           enroll-ssh-posix git-merge-plugin-version launcher-install preflight \
           prepare-ssh-identity privilege-broker-posix select-sections \
            test-roundhouse update-integrity; do
     bash -n "plugins/roundhouse/scripts/$s"
   done
   for s in plugins/roundhouse/scripts/lib/*.sh plugins/roundhouse/scripts/tests/*.sh; do
     bash -n "$s"
   done
   ```

   `scripts/lib/*.sh` are the CLI's sourced units and `scripts/tests/*.sh` the
   self-check's sourced sections. Neither is executable on its own.

2. **Lint** — `shellcheck --severity=warning -x -P SCRIPTDIR` (Linux job only)
   on the five substantial scripts: `roundhouse`, `collect-posix`,
   `launcher-install`, `test-roundhouse`, `update-integrity`. `-x` follows the `# shellcheck
   source=` directives, so `lib/` and `tests/` are analysed as part of the
   program that sources them rather than as standalone fragments.
3. **Integrity** — `plugins/roundhouse/scripts/update-integrity` followed by
   `git diff --exit-code -- plugins/roundhouse/integrity.json`. A dirty diff
   means the manifest was not regenerated after editing a covered file.
4. **Self-tests** — the transport and identity helpers each answer a
   `self-test` subcommand: `enroll-ssh-posix self-test`,
   `prepare-ssh-identity self-test`, `certify-ssh-node self-test`. Any new
   script in these lanes carries the same convention.
5. **Skill frontmatter** — every `plugins/roundhouse/skills/*/SKILL.md` has
   exactly `name` and `description`, both non-empty, with `name` equal to its
   directory name.
6. **Fixture suite** — `plugins/roundhouse/scripts/test-roundhouse`. CI runs
   `chmod -R go-w plugins/roundhouse` first; group- or world-writable files
   in the tree make the suite fail on strict-permission checks, so run the
   same `chmod` locally if the suite complains about permissions.
7. **Scoped fixture suites** — the same self-check re-entered with
   `ROUNDHOUSE_TEST_SCOPE`. A scope runs every section ahead of it and then
   the contract body that a default invocation only *defines* and never
   calls, so gate 6 does not cover them. The `scopes` job derives the list
   from the sections and the `scoped` matrix gives each one its own runner
   on both platforms — never hand-maintain a copy of that list. Locally:

   ```sh
   for scope in $(grep -ho 'ROUNDHOUSE_TEST_SCOPE:-}" != [a-z0-9-]*' \
       plugins/roundhouse/scripts/tests/*.sh | awk '{ print $NF }' | \
       grep -v '^u2-contracts$' | sort -u); do
     ROUNDHOUSE_TEST_SCOPE="$scope" plugins/roundhouse/scripts/test-roundhouse
   done
   ```

   Today that is `chezmoi-fixture`, `u1-characterization`, `u1-contracts`,
   `u2-broker-contracts`, `u2-enrollment-preparation-contracts`,
   `u2-enrollment-rollback-contracts`, `u2-enrollment-recovery-contracts`,
   `u2-collector-contracts`,
   `u2-upgrade-confirmation-contracts`, `u2-upgrade-rollback-contracts`,
   `u2-revocation-recovery-contracts`, `u2-revocation-rollback-contracts`,
   `u4-contracts`, `u5-contracts` and `macos-privilege-contracts`.
   Each U2 scope builds fresh keys, signed bundles, and native command fixtures.
   Enrollment preparation covers preview binding, collisions, and interrupted
   preparation and retirement. Enrollment rollback and recovery each start
   unenrolled with a real preview and lifecycle sentinel. Rollback covers every
   first-install failpoint; recovery keeps the complete contention, SIGKILL,
   and commit-finalization chain together.
   The collector, upgrade, and revocation scopes activate their fixtures
   through real enrollment preview and installation, then execute a real
   signed broker request. The collector scope checks requests, journals, and
   readiness. Upgrade confirmation checks cover races, abandoned pauses, stale
   owners, and the first three rollback failpoints; upgrade rollback checks cover
   the final four failpoints and draining retries. Together they retain the same
   seven-case rollback matrix, which the manual composite runs in full.
   Each revocation scope first completes a real upgrade to generation 2.
   Revocation recovery checks cover lock contention and repeated SIGKILL recovery;
   revocation rollback checks cover reserve interruption, failpoints, and final
   revocation. The manual composite retains every case in its original order.
   All rejection and lifecycle failure cases remain in the contract bodies.
   `ROUNDHOUSE_TEST_SCOPE=u2-contracts` still runs the complete U2 sequence
   manually; CI excludes that composite alias to avoid repeating the nine jobs.
   Serially the loop costs several times one
   default run, because the scopes share prefixes they each re-execute; CI
   parallelises it instead.

The Linux job also installs `openssh-server` before the scope validation.

`tests/90-real-jj.sh` is the one block no gate can force: it probes for
`jj >= 0.43`, drives two real working copies when it finds one, and prints a
loud NOTICE when it does not. CI runners have no `jj`, so run gate 6 once on
a jj-equipped host before merging anything that touches sync.

## Windows gates

PowerShell parse of every shipped `.ps1`, then `-SelfTest` on each of them
(`apply-windows.ps1` first, since it also validates the native boundary),
then a SHA-256 recheck of every file listed in `integrity.json`, then native
executor verification against a generated executor requirement.

## Before committing

- Keep skills usable by both Codex and Claude Code.
- Validate JSON manifests and skill frontmatter — gates 5 and the manifest
  parse above catch this, but do not push and wait for CI to tell you.
