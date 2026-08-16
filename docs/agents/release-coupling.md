# Release coupling

Changes under `plugins/` ship to installed fleets. They couple to a release:

1. Bump the version in both plugin manifests, in lockstep:
   - `plugins/roundhouse/.codex-plugin/plugin.json`
   - `plugins/roundhouse/.claude-plugin/plugin.json`
2. Regenerate the integrity manifest and commit it:

   ```sh
   plugins/roundhouse/scripts/update-integrity
   ```

3. Commit and push, then repin the marketplace from a checkout of
   [`novotnyllc/marketplace`](https://github.com/novotnyllc/marketplace):

   ```sh
   scripts/repin roundhouse <40-char-sha> <version>
   ```

   That one command updates every catalog file — both marketplace manifests
   and `.agents/plugins/plugin-versions.json` — and verifies them. Do not
   hand-edit those files.
4. Keep plugin lifecycle trust coupled to the bytes: every DSC `install`,
   `update`, or actual `enable` operation for a Codex-owned qualified plugin
   whose desired state is enabled must invoke
   `scripts/codex-plugin-hooks.mjs approve PLUGIN@MARKETPLACE` immediately
   afterward. A disabled desired state must not mutate Codex hook trust; a
   Codex source identity mismatch, untrusted hook, or locally modified Codex
   hook makes automatic approval refuse and hold the item until the Codex copy
   is refreshed/repaired or the hook is explicitly approved; a
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

Documentation-only changes (`docs/**`, `README.md`) need no version bump, no
integrity regeneration, no marketplace repin, and no fleet
redeploy/convergence pass — commit and push them directly. Only changes
under `plugins/` couple to the release machinery above.
