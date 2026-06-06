# Third-party notices & attribution

## Summary



While this SDK does not contain any code borrowed from other projects, we still want to **credit and respect** the projects this work is based
on. Their licenses (all permissive) are reproduced under
[`third-party-licenses/`](./third-party-licenses/) and summarized below.

## Reimplemented protocols / APIs (design sources)

| Project | Role for this SDK | License | Copyright | Source |
| --- | --- | --- | --- | --- |
| **Cloudflare Agents SDK** (`agents`) | Core agent protocol: `cf_agent_*` messages, RPC framing, state sync, the `UIMessage`-based chat protocol (`@cloudflare/ai-chat`), and URL routing reimplemented in `Agents` / `AgentsChat`. | MIT | © 2025 Cloudflare, Inc. | https://github.com/cloudflare/agents |
| **PartyKit `partysocket`** | WebSocket connection + reconnection/backoff behavior and URL construction reimplemented in `Agents` (`PartySocketURL`, `ReconnectingWebSocket`). | MIT | PartyKit; portions © 2010–2012 Joe Walnes (reconnecting-websocket) | https://docs.partykit.io/reference/partysocket-api |
| **PartyKit `partyserver`** | Server-routing semantics (`routePartykitRequest`, name addressing) that the client and the `E2E/` worker target. | ISC | © Sunil Pai / Cloudflare, Inc. | https://github.com/cloudflare/partykit |
| **Vercel AI SDK** (`ai`) | `UIMessage`, `UIMessagePart`, and `UIMessageChunk` type/field shapes reimplemented as Swift `Codable` types in `AgentsChat`. | Apache-2.0 | © 2023 Vercel, Inc. | https://ai-sdk.dev |

License texts: see [`third-party-licenses/`](./third-party-licenses/)
(`cloudflare-agents-sdk-MIT.txt`, `partysocket-MIT.txt`, `partyserver-ISC.txt`,
`vercel-ai-sdk-Apache-2.0.txt`). The full Apache-2.0 text is at
https://www.apache.org/licenses/LICENSE-2.0.



## Trademarks

"Cloudflare", "PartyKit", and "Vercel" and related marks belong to their
respective owners. This is an unofficial, independent project and is not
affiliated with, endorsed by, or sponsored by any of them.
