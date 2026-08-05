# UniFi Network API Usage

## Current Snapshot

`current-openapi.json` was copied from UDM Pro:

- Source: `root@unifi:/usr/lib/unifi/webapps/ROOT/api-docs/integration.json`
- Title: `UniFi Network API`
- Version: `10.3.58`
- OpenAPI: `3.1.0`
- Server path: `/integration`

Use the live console file when available, because Network app upgrades can change schemas.

## Base URL And Auth

The Integration API is exposed under the Network proxy path:

```sh
https://<console-host>/proxy/network/integration/v1
```

Use an API key generated in UniFi Network's Integrations area. Send it as:

```http
X-API-KEY: <api-key>
Accept: application/json
Content-Type: application/json
```

Do not retrieve API keys from browser storage. Ask the user for the key, use a password manager, use an environment variable they provided, or have the user create/configure one.

## Discovery Commands

List high-value endpoints:

```sh
jq -r '.paths | keys[] | select(test("firewall|policy|zone|traffic-matching|network|client|device|site"; "i"))' references/current-openapi.json
```

Inspect an endpoint:

```sh
jq '.paths["/v1/sites/{siteId}/firewall/policies"]' references/current-openapi.json
```

Inspect schemas:

```sh
jq -r '.components.schemas | keys[] | select(test("Firewall|Policy|Zone|Traffic"; "i"))' references/current-openapi.json
jq '.components.schemas["Create or update firewall policy"]' references/current-openapi.json
```

Discover sites:

```sh
curl -sk -H "X-API-KEY: $UNIFI_API_KEY" \
  "https://unifi.housenet.novotny.org/proxy/network/integration/v1/sites"
```

## Firewall Policy Workflow

For firewall policy tasks:

1. `GET /v1/sites/{siteId}/firewall/policies?limit=200`
2. `GET /v1/sites/{siteId}/firewall/policies/ordering`
3. Identify referenced zones and traffic matching lists.
4. Create or patch only the requested policy.
5. Use the ordering endpoint if priority matters.
6. Verify compiled gateway rules over SSH when packet behavior matters.

Important endpoint set:

- `GET/POST /v1/sites/{siteId}/firewall/policies`
- `GET/PUT/PATCH/DELETE /v1/sites/{siteId}/firewall/policies/{firewallPolicyId}`
- `GET/PUT /v1/sites/{siteId}/firewall/policies/ordering`
- `GET /v1/sites/{siteId}/firewall/zones`
- `GET/POST /v1/sites/{siteId}/traffic-matching-lists`

## Guardrails

- Prefer managed API changes over UI automation, direct database writes, or shell hooks.
- Do not use global CyberSecure region blocking when the user asks for a host-specific block.
- Do not create broad network blocks when the user asks for a specific host, service, or zone.
- For allow-then-block patterns, verify the allow policy has a lower index than the block policy.
- For inbound Internet-to-LAN policy changes, verify rules compile before existing port-forward accepts.
- If using a temporary emergency runtime rule, label it clearly, keep it host-scoped, and remove it after managed config is confirmed.
