# Verification

`.github/workflows/validate.yml` checks POSIX syntax/integrity in `posix`,
ordinary sections in `sections`, scoped contracts in `scoped`, and helper
self-tests in `helpers`, each on ubuntu-latest and macos-latest. `select`
uses `scripts/select-sections` and its `--scopes`/`--helpers` modes to choose
PR coverage from changed paths; main pushes select everything. Unknown inputs within the tested surface
fall back to full coverage. Unrelated changes need no extra scopes or helpers.
The workflow also runs `actionlint`, native `windows` checks, and the stable
`ci-ok` gate over all results. Reproduce the relevant gates locally before
pushing plugin changes.

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
   script in these lanes carries the same convention. CI runs enrollment's
   Linux and macOS fixture lifecycles in separate jobs on **both actual runner
   OSes**, using `ROUNDHOUSE_SSH_SELFTEST_PLATFORM=linux` or `macos`. Each
   selected run includes the WSL rejection check; an unset selector runs both
   lifecycles and WSL. Other helpers run once per runner OS.
5. **Skill frontmatter** — every `plugins/roundhouse/skills/*/SKILL.md` has
   exactly `name` and `description`, both non-empty, with `name` equal to its
   directory name.
6. **Fixture suite** — `plugins/roundhouse/scripts/test-roundhouse` remains
   the full manual release gate. CI uses `ROUNDHOUSE_TEST_ONLY` to run selected
   section numbers independently over the shared `00/05/07` harness. Sections
   at or after 90 also load the real-jj bootstrap prerequisite. Group- or
   world-writable plugin files fail strict-permission checks; use
   `chmod -R go-w plugins/roundhouse` locally, as the scoped CI jobs do.
7. **Scoped fixture suites** — re-enter the same driver with
   `ROUNDHOUSE_TEST_SCOPE`. Most scopes invoke contract bodies that the default
   suite only defines, so gate 6 does not replace them. `select` derives the
   full scope list from source guards, excluding the manual `u2-contracts`
   composite; `scoped` runs each selected scope on both platforms. Discover
   and run the complete scope set locally with:

   ```sh
   for scope in $(grep -ho 'ROUNDHOUSE_TEST_SCOPE:-}" != [a-z0-9-]*' \
       plugins/roundhouse/scripts/tests/*.sh | awk '{ print $NF }' | \
       grep -v '^u2-contracts$' | sort -u); do
     ROUNDHOUSE_TEST_SCOPE="$scope" plugins/roundhouse/scripts/test-roundhouse
   done
   ```

   Five scopes partition ordinary section 68: `plan-packages`, `plan-agents`,
   `plan-projects`, `plan-chezmoi`, and `plan-auth`. Each starts with only
   `00/05/07/68` and explicitly builds its snapshot/readiness prerequisites.
   CI selects all five whenever section 68 is required and omits the serial
   68 job. `ROUNDHOUSE_TEST_ONLY=68` and the default manual suite retain every
   original assertion in the original lifecycle order.

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
   manually; CI excludes that composite alias to avoid repeating the nine scopes.
   Each scoped invocation owns a fresh fixture root; running another scope
   first is not a prerequisite. CI parallelizes them rather than running the
   complete local loop serially.

Linux helper, section, and scope jobs install `openssh-server` only if `sshd`
is absent, with bounded retries.

The `sections` jobs install pinned `jj` 0.44.0 and `yq` 4.44.3 and set
`ROUNDHOUSE_REQUIRE_REAL_JJ=true`. `tests/90-jj-bootstrap.sh` requires usable
`jj >= 0.43` and `yq` when that flag is set; CI therefore fails rather than
skipping real-jj coverage. Local runs without the flag print a NOTICE and
skip those fixtures when dependencies are unavailable. Set the flag when
validating sync changes locally, for example:

```sh
ROUNDHOUSE_TEST_TIER=jj ROUNDHOUSE_REQUIRE_REAL_JJ=true \
  plugins/roundhouse/scripts/test-roundhouse
```

## Windows gates

PowerShell parse of every shipped `.ps1`, then `-SelfTest` on each of them
(`apply-windows.ps1` first, since it also validates the native boundary),
then a SHA-256 recheck of every file listed in `integrity.json`, then native
executor verification against a generated executor requirement.

## Before committing

- Keep skills usable by both Codex and Claude Code.
- Validate JSON manifests and skill frontmatter — gates 5 and the manifest
  parse above catch this, but do not push and wait for CI to tell you.
