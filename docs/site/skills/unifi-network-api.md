# UniFi network API

UniFi Network API drives your UDM Pro's Network app through the official
Integration API instead of browser UI automation, for repeatable changes
to firewall policies, policy ordering, zones, networks, clients, devices,
DNS policies, and traffic-matching lists. It's how Codex inspects or
changes UniFi Network settings without clicking through the console by
hand.

## When to use it

- "Block this one device from reaching the internet, but leave the rest of
  the guest network alone."
- "What's the current firewall policy order on the LAN?"
- "Add a DNS policy for the new IoT VLAN."
- Any UniFi Network config change you'd otherwise make by clicking through
  the console — if the Integration API covers it, this skill uses the API
  first.

## How it works

### Source of truth: the live console spec, not a stale copy

- **Live console OpenAPI spec:** `/usr/lib/unifi/webapps/ROOT/api-docs/integration.json`
  on `root@unifi`.
- **Saved snapshot:** `references/current-openapi.json`, captured from the
  operator's UDM Pro (currently Network `10.3.58`).
- **Notes and examples:** `references/api-usage.md`.

Before relying on a schema, the skill prefers refreshing the live spec over
trusting the saved snapshot, because a Network app upgrade can change it:

```sh
scp root@unifi:/usr/lib/unifi/webapps/ROOT/api-docs/integration.json "$SKILL_DIR"/references/current-openapi.json
jq -r '[.info.title,.info.version,.openapi,.servers[0].url] | @tsv' "$SKILL_DIR"/references/current-openapi.json
```

The spec is queried with `jq`, never pasted whole into context.

### Workflow

1. Read `references/api-usage.md` for auth, base URLs, and guardrails.
2. Inspect the exact endpoint and schema in `references/current-openapi.json`.
3. Use an API key from you or the environment — never mined from browser
   cookies, local storage, or a password/session store.
4. For a mutation, fetch current state first, prepare the minimal change,
   and preserve every field and ordering that isn't part of the request.
5. Prefer Integration API writes over browser UI control.
6. Fall back to browser control only when the API lacks coverage, or to
   confirm a confusing UI-only behavior.

### Talking to the API

The Integration API sits under the Network proxy path:

```
https://<console-host>/proxy/network/integration/v1
```

Requests carry the API key as a header, not a query parameter:

```http
X-API-KEY: <api-key>
Accept: application/json
Content-Type: application/json
```

Discovering endpoints and schemas is all `jq` over the saved spec:

```sh
jq -r '.paths | keys[] | select(test("firewall|policy|zone|traffic-matching|network|client|device|site"; "i"))' \
  references/current-openapi.json

jq '.paths["/v1/sites/{siteId}/firewall/policies"]' references/current-openapi.json
jq -r '.components.schemas | keys[] | select(test("Firewall|Policy|Zone|Traffic"; "i"))' \
  references/current-openapi.json
```

### Firewall policy workflow

For firewall policy changes specifically:

1. `GET /v1/sites/{siteId}/firewall/policies?limit=200`
2. `GET /v1/sites/{siteId}/firewall/policies/ordering`
3. Identify the zones and traffic-matching lists the policy references.
4. Create or patch only the requested policy.
5. Use the ordering endpoint if priority matters — an allow-then-block
   pattern only works if the allow policy has a lower index than the block.
6. Verify compiled gateway rules over SSH when packet-level behavior
   matters, not just the API's view of config.

The important endpoint set: `GET/POST .../firewall/policies`,
`GET/PUT/PATCH/DELETE .../firewall/policies/{firewallPolicyId}`,
`GET/PUT .../firewall/policies/ordering`, `GET .../firewall/zones`, and
`GET/POST .../traffic-matching-lists`.

### Verification after a change

- Verify API/controller state with `GET`, or read-only Mongo if the API
  doesn't expose it.
- Verify user-defined ordering when rule order matters.
- Verify compiled gateway behavior over SSH with `iptables-save`, `ipset`,
  or equivalent live firewall inspection — the API's view and the
  gateway's compiled rules are not automatically the same thing.
- Remove any temporary runtime-only emergency rule once the managed policy
  is compiled and confirmed.

## Scope

- API keys come from you, a password manager, or an environment variable you
  have already provided; browser cookies, local storage, and password/session
  stores remain outside key discovery.
- Persistent configuration flows through the supported API. Mongo remains a
  read-only surface for forensics and emergency-rollback investigation.
- Persistent shell hooks and custom on-boot scripts stay outside UniFi's
  configuration path.
- Scoped blocking for an "Alexandria"/Synology-style single host uses an
  explicit destination-scoped firewall policy for the named host, service,
  or zone; global CyberSecure region blocking remains a separate broader
  policy.
- A temporary emergency runtime rule carries a clear label, stays
  host-scoped, and is removed after the managed policy is confirmed compiled.

## Example session

> **You:** "Block the smart TV from reaching the internet, but leave the
> rest of the guest network alone."
>
> **What happens:** the skill checks the live console spec is current
> (refreshing the snapshot if stale), fetches existing firewall policies
> and their ordering, identifies the TV's client/device entry and the
> relevant zone, and creates one destination-scoped block policy for that
> device rather than touching the guest zone's overall CyberSecure
> settings. It checks the new policy's index against any existing allow
> rules that need to stay effective, applies the ordering fix if needed,
> and verifies over SSH that the compiled gateway rules actually reflect
> the block.

> **You:** "What's currently blocking the IoT VLAN from the LAN?"
>
> **What happens:** the skill queries `firewall/policies` and
> `firewall/zones` for the relevant site, filters to policies naming the
> IoT VLAN as source or destination, and reports the matching policies with
> their ordering — read-only, no changes made.
