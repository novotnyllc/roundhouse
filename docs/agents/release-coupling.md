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
   `update`, or `enable` path for a Codex-owned qualified plugin must invoke
   `scripts/codex-plugin-hooks.mjs approve PLUGIN@MARKETPLACE` immediately
   afterward. Claude-only plugins have no Codex hook state and are explicitly
   skipped after the ownership check. Keep the Node/login-shell requirement
   and native-Windows Node gap documented in `fleet-update`.

Never treat an installed plugin cache as the source repository.

## Documentation-only exemption

Documentation-only changes (`docs/**`, `README.md`) need no version bump, no
integrity regeneration, no marketplace repin, and no fleet
redeploy/convergence pass — commit and push them directly. Only changes
under `plugins/` couple to the release machinery above.
