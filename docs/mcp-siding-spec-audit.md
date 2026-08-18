# mcp-siding vs MCP 2026-07-28

Audit of `plugins/roundhouse/scripts/mcp-siding.mjs` against the current MCP
specification. The shim pins `PROTOCOL_VERSION = "2025-06-18"`; the current
revision is **2026-07-28**, two revisions on (`2025-11-25` sits between).

## What changed under us

`2026-07-28` removes the `initialize` handshake as the basis of the protocol.
Every request now declares its own version in `_meta`
(`io.modelcontextprotocol/protocolVersion`), the server accepts or rejects each
request independently, and there is no session negotiation. The spec calls the
two styles **modern** (per-request metadata, `2026-07-28`+) and **legacy**
(`initialize` handshake, `2025-11-25` and earlier).

## Where the shim sits

The shim is a proxy with two faces, and both are currently legacy:

- **To the client** it answers `initialize` locally and reports
  `protocolVersion: "2025-06-18"`. It is a legacy *server*.
- **To the backend** it always opens with `initialize`. It is a legacy *client*.

Read against the spec's compatibility matrix, that is fine today and fails in
both directions later:

| Client | Server | Outcome |
| --- | --- | --- |
| Modern | Legacy | **Fails** — when the harness modernizes, the shim stops working |
| Legacy | Modern | **Fails** — when Fusion modernizes, the shim stops working |
| Dual-era | either | Works |

The target is therefore **dual-era on both faces**, not "upgrade to modern".
Fusion is legacy and will be for a while; the shim must keep speaking legacy to
it while being able to serve a modern client.

## Gaps

Ordered by when they bite, not by size.

### 1. MRTR interim results rejected as malformed — DONE (0.9.1)

`validateResultShape` requires `Array.isArray(result.content)` for `tools/call`
and `Array.isArray(result.tools)` for `tools/list`. Under `2026-07-28` a
multi-round-trip request returns an interim result with
`resultType: "input_required"` which carries **neither**. The shim would raise
`MalformedResponse` and turn a legitimate interim response into an error.

This is the only gap that breaks purely from the *backend* modernizing, with no
change on the client side, so it is first. The fix is narrow: treat a result
carrying `resultType: "input_required"` as valid and pass it through untouched.

### 2. `server/discover` — DONE (0.9.3)

It is also the stdio backward-compatibility probe: a dual-era client sends
`server/discover` first and falls back to `initialize` on any non-modern error.
The shim currently answers method-not-found, which a correct dual-era client
*will* read as "legacy" and recover from — so this degrades gracefully rather
than failing. It is still a MUST, and implementing it is what makes the shim
legible to a modern client.

Response needs `supportedVersions`, `capabilities`, `_meta` serverInfo, and the
caching hints (`ttlMs`, `cacheScope`).

### 3. Per-request `_meta` version + `UnsupportedProtocolVersionError` — DONE (0.9.3)

A modern client's requests carry `_meta.io.modelcontextprotocol/protocolVersion`
and expect either service or a `-32022` error listing supported versions. The
shim ignores `_meta` entirely, so a modern client is served under legacy
semantics by accident — the matrix's "may even process an era-ambiguous method
under legacy semantics" case.

### 4. `resultType` on synthesized results — DONE (0.9.3)

The shim manufactures results in two places — the offline `tools/list` cache
fallback and the `isError` result for an unreachable backend. Modern results
carry `resultType: "complete"`. Absent, a modern client cannot distinguish a
complete result from an interim one.

### 5. Backend-side era detection — DONE (0.9.5)

The shim should probe `server/discover` before falling back to `initialize`, per
the Streamable HTTP backward-compatibility rules (attempt a modern request,
inspect the body of a `400` before falling back). The spec notes era is a
property of the server and SHOULD be cached for the lifetime of the origin —
which fits the shim's existing per-session connection state.

## Already correct

- **Caching.** `tools/list` is explicitly cacheable in `2026-07-28`, with
  serving a stale copy during downtime explicitly permitted ("Clients MAY serve
  stale responses if errors occur during re-fetching... server downtime"). The
  shim's offline fallback is the blessed behaviour, and it labels that response
  `ttlMs: 0` so the client does not re-cache a stale copy as fresh.
- **Live pass-through.** Fusion sends no `ttlMs`, which the spec defines as
  immediately stale, so always re-fetching while the backend is up is correct.
- **`listChanged`.** Advertised, with change detection driven by a jittered,
  backing-off poll — the spec requires jitter and backoff of any implementation
  that chooses to poll.
- **`MCP-Protocol-Version` header** is sent on requests once negotiated.

## Status

Gaps 1–4 are done: the shim now answers `server/discover`, honours a
per-request `_meta` protocol version (rejecting an unserved one with `-32022`
and the list it does serve), and marks synthesized results `resultType:
"complete"`. It advertises `2026-07-28`, `2025-11-25` and `2025-06-18`, so it
is dual-era on the CLIENT face while still speaking legacy `initialize` to the
backend.

Gap 5 is done too: `probeBackendEra()` sends `server/discover` before the
handshake and caches the verdict for the origin's lifetime. A modern backend
skips `initialize` entirely and receives `_meta` on every request; a legacy one
is byte-identical to before; an unreachable one stays UNDECIDED rather than
being cached as legacy, because downtime is not evidence of an era.

**Verified against a mock only.** No desktop backend speaks 2026-07-28 yet, so
the modern branch has never met a real server. What the test pins is the branch
logic, not field behaviour — worth saying plainly rather than letting a green
run imply more.

## Suggested sequencing

1. Gap 1 alone, as a small fix — it is the only one that can break without a
   client change, and it is a few lines.
2. Gaps 2–4 together as "serve a modern client": `server/discover`, `_meta`
   version handling, `-32022`, `resultType`. This is the dual-era server face.
3. Gap 5 last: the dual-era client face. Nothing needs it until a backend
   modernizes, and Fusion has not.
