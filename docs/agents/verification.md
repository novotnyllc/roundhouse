# Verification

`.github/workflows/validate.yml` runs two jobs: `posix` (ubuntu-latest and
macos-latest) and `windows` (windows-latest). Reproduce them locally before
pushing plugin changes.

## POSIX gates

1. **Syntax** — `bash -n` on every shipped Bash script:

   ```sh
   for s in roundhouse certify-ssh-node collect-posix enroll-privilege-posix \
            enroll-ssh-posix prepare-ssh-identity privilege-broker-posix \
            test-roundhouse update-integrity; do
     bash -n "plugins/roundhouse/scripts/$s"
   done
   ```

2. **Lint** — `shellcheck --severity=warning` (Linux job only) on the four
   substantial scripts: `roundhouse`, `collect-posix`, `test-roundhouse`,
   `update-integrity`.
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

The Linux job also installs `openssh-server` before the scope validation.

## Windows gates

PowerShell parse of every shipped `.ps1`, then `-SelfTest` on each of them
(`apply-windows.ps1` first, since it also validates the native boundary),
then a SHA-256 recheck of every file listed in `integrity.json`, then native
executor verification against a generated executor requirement.

## Before committing

- Keep skills usable by both Codex and Claude Code.
- Validate JSON manifests and skill frontmatter — gates 5 and the manifest
  parse above catch this, but do not push and wait for CI to tell you.
