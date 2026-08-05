---
name: unifi-network-api
description: Use the official UniFi Network Integration API for managed UniFi console automation, especially firewall policies, policy ordering, zones, networks, clients, devices, DNS policies, traffic matching lists, and other Network app configuration. Use when the user asks Codex to inspect or change UniFi Network settings from UDM Pro.
---

# UniFi Network API

Use UniFi Network's managed Integration API before browser UI automation for repeatable Network app configuration changes.

## Source Of Truth

- Live console OpenAPI spec: `/usr/lib/unifi/webapps/ROOT/api-docs/integration.json` on `root@unifi`.
- Saved snapshot: `references/current-openapi.json` from the operator's UDM Pro, currently Network `10.3.58`.
- Notes and examples: `references/api-usage.md`.

Before relying on a schema, prefer refreshing or checking the live console spec:

```sh
scp root@unifi:/usr/lib/unifi/webapps/ROOT/api-docs/integration.json "$SKILL_DIR"/references/current-openapi.json
jq -r '[.info.title,.info.version,.openapi,.servers[0].url] | @tsv' "$SKILL_DIR"/references/current-openapi.json
```

Query the spec with `jq`; do not paste the whole OpenAPI file into context.

## API Workflow

1. Read `references/api-usage.md` for auth, base URLs, and guardrails.
2. Inspect the exact endpoint/schema in `references/current-openapi.json`.
3. Use an API key from the user or environment; do not mine browser cookies, local storage, or password/session stores.
4. For mutations, fetch current state first, prepare the minimal change, and preserve unrelated fields/order.
5. Prefer Integration API writes over browser UI control.
6. Use browser control only when the API lacks coverage or to confirm a confusing UI-only behavior.
7. Avoid direct Mongo writes for persistent configuration. Use Mongo only for read-only forensics or emergency rollback investigation.
8. Never add persistent shell hooks or custom on-boot scripts for UniFi config.

## Verification

After firewall or policy changes:

- Verify API/controller state with `GET` or, if needed, read-only Mongo.
- Verify user-defined ordering if rule order matters.
- Verify compiled gateway behavior over SSH with `iptables-save`, `ipset`, or equivalent live firewall inspection.
- Remove any temporary runtime-only emergency rules once managed policy rules are compiled and confirmed.

For Alexandria/Synology-style scoped region blocking, use explicit destination-scoped firewall policies rather than global CyberSecure region blocking when the user wants only one host affected.
