# Release coupling

Feature and fix PRs do not bump the version. Leave both plugin manifests at
main's version; a PR that edits a covered file still runs
`plugins/roundhouse/scripts/update-integrity` so `integrity.json` matches its
bytes (CI checks that). Merge PRs in whatever order is ready - there is no
version sequencing between them.

The version is bumped once, at release, when main's accumulated changes ship
to installed fleets. A release is bookkeeping, not a review event: no
whole-candidate review, no extra test pass beyond main's CI.

1. Bump the version in both plugin manifests, in lockstep, to one patch above
   main:
   - `plugins/roundhouse/.codex-plugin/plugin.json`
   - `plugins/roundhouse/.claude-plugin/plugin.json`
2. Regenerate the integrity manifest:

   ```sh
   plugins/roundhouse/scripts/update-integrity
   ```

3. Commit both to main, then repin the marketplace from a checkout of
   [`novotnyllc/marketplace`](https://github.com/novotnyllc/marketplace):

   ```sh
   scripts/repin roundhouse <40-char-sha> <version>
   ```

   That one command updates every catalog file — both marketplace manifests
   and `.agents/plugins/plugin-versions.json` — and verifies them. Do not
   hand-edit those files.

Lifecycle rule for plugin changes (applies to the code, not the release step):

- Keep plugin lifecycle trust coupled to the bytes: every DSC `install`,
  `update`, or actual `enable` operation for a Codex-owned qualified plugin
  whose desired state is enabled must invoke
  `scripts/codex-plugin-hooks.mjs approve PLUGIN@MARKETPLACE` immediately
  afterward. A disabled desired state must not mutate Codex hook trust; a
  Codex source identity mismatch, untrusted hook, or locally modified Codex
  hook makes automatic approval refuse and hold the item until the Codex copy
  is refreshed/repaired or the hook is explicitly approved. Automatic approval
  only carries existing trust: a hook that reads `modified` because Codex
  advanced the copy is re-trusted at its new hash only when the copy is from
  the verified source at the expected SHA and its installed tree is
  byte-identical to Claude's verified install there; a
  steady-state enabled no-op must not invoke the manager verb or re-approve
  locally modified hooks. Claude-only plugins have no Codex hook state and are
  explicitly skipped after the ownership check. Keep the Node/login-shell
  requirement and native-Windows resolver order documented in `fleet-update`:
  PATH Node first, then the Codex-bundled runtime (effectively guaranteed
  because the helper runs only where Codex exists), Claude-bundled Node only
  as a last fallback, and exit 69 with all three probe classes plus WSL
  recovery when none is available.

Never treat an installed plugin cache as the source repository.

## Documentation-only exemption

Documentation-only changes (`docs/**`, `README.md`) need no integrity
regeneration, no marketplace repin, and no fleet redeploy/convergence pass.
Only changes under `plugins/` ship with the next release.
