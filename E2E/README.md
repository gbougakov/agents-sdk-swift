# End-to-end test harness

A minimal, self-contained Cloudflare Agents worker used to verify the Swift
client against a real server over WebSocket. It depends only on the published
`agents` package — it does **not** require the upstream monorepo.

## What's here

- `src/server.ts` — a worker exposing two plain agents:
  - **`StateAgent`** — `counter`/`items` state with `@callable` `increment`,
    `setCounter`, `addItem`, `resetState` (exercises state sync + RPC).
  - **`CallableAgent`** — pure RPC: `add`, `echo`, `getTimestamp`,
    `slowOperation`, `throwError`.
- `wrangler.jsonc` — DO bindings + SQLite migrations.

### Local-dev note (`x-partykit-room`)

`routeAgentRequest` routes by URL path and relies on `ctx.id.name`, which local
`wrangler dev`/workerd does **not** populate for `idFromName()`-addressed Durable
Objects — so PartyServer's `.name` guard throws at session setup. The worker
works around this by stamping the recognized `x-partykit-room` header in
`routeAgentRequest`'s `onBeforeConnect`/`onBeforeRequest` hooks. This is a
local-dev shim only; deployed Cloudflare populates `.name` natively and the
client protocol is unaffected.

## Run it

```bash
# 1. Start the worker (terminal 1)
cd E2E
npm install
npm run dev            # → Ready on http://127.0.0.1:8787

# 2. Run the Swift client smoke test (terminal 2, from repo root)
swift run E2ESmoke localhost:8787
```

Expect `RESULT: PASS` with 12/12 checks. The smoke client lives at
`Sources/E2ESmoke/main.swift`.

## Scope

Covers the **core client**: connection/identity, bidirectional state sync,
typed RPC (args + results), server→client state broadcast, and error
propagation. The chat layer (`AgentsChat`) is unit-tested but not yet covered
here (needs an `AIChatAgent` + model backend).
