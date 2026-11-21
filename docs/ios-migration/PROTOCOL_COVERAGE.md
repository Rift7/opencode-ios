# Protocol coverage — `/api/event` and the REST surface

What this migration has adopted from the audited server contract, what is modelled but has no call site
yet, and what is deliberately deferred. Coverage is per route and per event type, so a later phase cannot
claim a route because a model for it exists.

Baseline: `dev = 7358160e808fb1870eeb20f5da8df832667019d1`. Sources are relative to
`server/src/main/kotlin/ai/opencode/server/`. Freshness was checked against that commit: no file below
changed between the audit and the baseline, and nothing in `docs/parity/server.md` records a competing iOS
shape for the adopted rows.

Status vocabulary:

- **implemented** — the Swift call exists, is reachable through `OpenCodeClient`, and a test asserts its
  request and/or decode.
- **modelled** — the wire type exists and is decoded in a test, but no feature calls the route yet.
- **documented** — the route is listed with its audited method/timeout/idempotency, with no Swift type yet.
- **deferred** — belongs to a later phase, named here so it is not mistaken for missing work.

## Transport and retry

| Behaviour | Audited source | Swift | Status |
| --- | --- | --- | --- |
| One HTTP client per server, one retry layer per request | `OpenCodeTransport.kt` (`f79a895e`, 2026-11-14), `live/LiveTransport.kt` | `OpenCodeCore/Transport/{HTTPTransport,URLSessionTransport}.swift` | implemented — one `URLSession` per live transport, ephemeral, no cookies or cache; every client call goes through `NetworkRetry` once |
| `Accept: application/json`; `Content-Type` only with a body | `live/LiveTransport.kt` | `OpenCodeServer/Address/OpenCodeServer.swift` (`request(path:…)`) | implemented — caller supplies the header; JSON bodies are encoded by the caller |
| Basic auth from the pairing token; username defaults to `opencode` | `OpenCodeServer.kt` | `OpenCodeServer.basicAuthorization`, `.wireHeaders` | implemented + tested |
| `location[directory]` query, escaped as `location%5Bdirectory%5D` | `internal/Urls.kt` (`5fa3aab0`, 2026-10-24) | `OpenCodeServer.endpoint(path:query:)`, percent encoders | implemented + tested (path and query encoding, `/` kept, `[` `]` escaped) |
| Timeouts: default 10 s; probe 3.5 s; pairing redeem 15 s; event read 90 s | `live/LiveTransport.kt`, `ServerLink.kt` | `HTTPRequest.timeout`, call sites | implemented for the routes above; per-route long timeouts listed below |
| Redirect control per call | `withTimeout(followsRedirects)` | `HTTPRedirectPolicy`, `HTTPRedirectRule` | implemented (rule tested; session wiring not exercisable through the fixture `URLProtocol`) |
| Credentials never leave their origin on a redirect | audited in code comments; no test | `HTTPRedirectRule`, `RedirectGuard` | implemented + rule tested (same-origin re-applies headers, cross-origin refuses, scheme change refuses) |
| Cleartext policy: private, overlay and local names only | `TransportSecurity.kt` (`f79a895e`) | `OpenCodeCore/Network/HostAddress.swift` (`TransportSecurity`) | implemented + tested (RFC 1918, CGNAT, link-local, ULA, `.local`, unqualified, `ts.net`/`netbird*`/`home.arpa`/`internal`) |
| ATS, local-network permission | not an Android concept | `ios/OpenCode/Info.plist` | implemented: `NSAllowsLocalNetworking`, per-domain cleartext exceptions for the overlay names, `NSLocalNetworkUsageDescription`; no global ATS disable |
| Five-attempt request policy, send/stream/wait presets, equal jitter, retry window, `Retry-After` cap | `retry/NetworkRetry.kt` (`f79a895e`) | `OpenCodeServer/Retry/{RetryPolicy,NetworkRetry}.swift` | implemented + tested (ceiling, window, attempts, offline wait, `Retry-After` seconds/date, cap) |
| Unsafe requests resent only when provably unsent | `RequestIdempotency`, `retryVerdict` | same | implemented + tested (interrupted unsafe write sent once; `notSent` retried; 408/429/503 retried) |
| Cancellation is never a reachability failure | `retryVerdict` | `NetworkRetry.run`, transport delegate | implemented + tested |
| Under tests a request is sent once unless a policy is set | `NetworkRetry.currentPolicy` | `OpenCodeClient.live(…, policy: .once)` | implemented — the test factory defaults to `.once` |
| Offline detection and a network-path wait | `retry/NetworkPath.kt` | `RetryEnvironment` | deferred to P5: the seam exists; nothing observes the path yet |
| Alternate-origin routing between candidate addresses | `retry/ServerLink.kt`, `ServerContact.kt` | `OpenCodeServer.candidateURLs`, `preferredURLs` | partial — candidates are carried and pairing orders them; the live race/watchdog is P5 |

## REST routes

Every response the adopted routes read is decoded with the synthesized `Codable` rules the audited codec
uses: unknown keys ignored, absent optionals nil, a present wrong type rejects the payload.

| Method | Path | Audited source | Swift | Status |
| --- | --- | --- | --- | --- |
| GET | `/api/info` | `live/LiveConnection.kt` `requestHealth` (`5e4b4219`, 2026-11-16), `ServerInfoPayload` | `ServerInfo`, `Operations.health` | implemented + tested: 3.5 s, one attempt, redirects refused, address-identification rule |
| GET | `/auth/connect/{code}` | `live/LiveConnection.kt` `requestRedeemPairing` | `Operations.redeemPairing` | implemented + tested: one GET per candidate, no `Authorization`, 15 s, `.unsafe`, redirects refused, 401/404 copy |
| GET | `/api/project` | `live/LiveFamily.kt` | `Operations.projects`, `ProjectPayload` | implemented + tested: bare array, display-name and repository-slug rules |
| GET | `/api/session` | `live/LiveSessions.kt` `requestSessionPage`, `requestRootSessions` (`8566441f`, 2026-11-17) | `Operations.sessionPage` | implemented + tested: `limit,parentID=null,archived=false,order=desc,search`, cursor page, archived/child filter, empty-page end |
| GET | `/api/session/{id}` | same | `Operations.getSession` | implemented + tested: `time.updated` ms, title placeholder, archive, revert, notification metadata |
| GET | `/api/session/active` | `live/LiveSessions.kt`, `live/LiveFamily.kt` | `Operations.activeSessionIDs` | implemented + tested: map envelope |
| GET | `/api/event` | `live/LiveEvents.kt` (`4c1e0054`, 2026-11-20) | `EventStream`, `EventStreamRunner` | implemented + tested: SSE, batching, watchdog, 401 stop, reconnect |
| GET | `/api/session/{id}/message?order=desc&limit=N` | `live/LiveTranscript.kt` | — | deferred to P8 (transcript) |
| GET | `/api/session/{id}/message?limit=N&cursor=…` | same | — | deferred to P8 |
| GET | `/api/session/{id}/message/{messageID}` | same | — | deferred to P8 |
| POST | `/api/session/{id}/prompt` (30 s, idempotent by message id) | `live/LivePrompts.kt` | `PromptBody` (core fields only) | modelled + encoded in tests; call site deferred to P9 (composer) |
| POST | `/api/session/{id}/interrupt?resume=true` | `live/LiveSessions.kt` `requestInterrupt` | — | deferred to P7 |
| POST | `/api/session` (create; idempotent only with a client id) | `live/LiveSessions.kt` `requestCreateSession` | — | deferred to P6/P7 |
| PATCH | `/api/session/{id}` (rename; empty title is unsafe, 60 s) | same `requestRenameSession` | — | deferred to P6 |
| PATCH | `/api/session/{id}` (archive/unarchive, idempotent) | same `requestSetArchived` | — | deferred to P6 |
| DELETE | `/api/session/{id}` | same `requestDeleteSession` | — | deferred to P6 |
| POST | `/api/session/{id}/move` (unsafe, 15 s) | same `requestMoveSession` | — | deferred to P6 |
| POST | `/api/session/{id}/view` (idempotent watermark) | same `requestViewSession` | — | deferred to P7 |
| POST | `/api/session/{id}/fork` | same `requestForkSession` | — | deferred to P7 |
| POST | `/api/session/{id}/compact` | same `requestCompactSession` | — | deferred to P7 |
| POST | `/api/session/{id}/revert/stage`, `DELETE …/revert` | same | — | deferred to P7 |
| POST | `/api/session/{id}/background` | same | — | deferred to P7 |
| GET | `/api/experimental/session/{id}/export` (60 s) | same `requestExportSession` | — | deferred to P7 |
| POST | `/api/experimental/session/{id}/wait` (25 s poll, idempotent) | same `requestWaitForIdle` | — | deferred to P7 (the wait loop owns its retries) |
| GET | `/api/session/{id}/inbox` | `live/LivePrompts.kt` | — | deferred to P7 |
| PATCH | `/api/session/{id}/inbox/{inputID}` (unsafe; 409 or read-back settles) | same | — | deferred to P7 |
| DELETE | `/api/session/{id}/inbox/{inputID}` (idempotent) | same | — | deferred to P7 |
| GET | `/api/permission/request`, `/api/form` (60 s, location-scoped) | `live/LiveRequests.kt` | — | deferred to P7 |
| POST | `…/permission/{requestID}/reply`, `…/form/{formID}/reply` | same | — | deferred to P7 |
| GET | `/api/shell`, `/api/shell/{id}`, `/api/shell/{id}/output`, `DELETE /api/shell/{id}` | same | `ShellInfoPayload`, `ServerShell` | modelled + decoded in tests; call sites deferred to P7 |
| GET | `/api/experimental/job`, `POST …/{jobID}/cancel` | same | `JobInfoPayload`, `ServerJob` | modelled + decoded in tests (event); call sites deferred to P7 |
| GET | `/api/model`, `/api/model/default` | `live/LiveCatalog.kt` | `ModelRef` only | deferred to P9/P11 |
| GET | `/api/agent`, `/api/skill`, `/api/command`, `/api/plugin`, `/api/mcp`, `/api/integration` | `live/LiveCatalog.kt` | — | deferred to P9/P11 |
| GET | `/api/fs/list`, `/api/fs/find`, `/api/fs/read/{rel}` | `live/LiveFiles.kt` | — | deferred to P6/P9/P10 |
| POST | `/api/experimental/fs/write` | `live/LiveFiles.kt` | — | deferred to P9 |
| GET | `/api/experimental/media/{hash}` | `live/MediaReferenceFetch.kt` | — | deferred to P10 |
| POST | `/api/rpc/mobile-notifications/pair` | `live/LiveConnection.kt` | — | deferred to P12 (Experimental, off) |
| — | `X-OpenCode-Capabilities: experimental-media-uri` | `live/LiveTransport.kt` | event stream only | implemented on the event stream; other calls advertise it when their phase adds media |

Notes that stay visible:

- `GET /api/project` returns a **bare array**, not `{data: …}`. `GET /api/session` returns `{data, cursor}`.
- `/api/session` with `parentID=null` is a query value, not a JSON null.
- `time.updated` and `time.archived` are JSON numbers in milliseconds; `time.idle`/`time.viewed` are echoed
  to `/view` unchanged.
- `pid` is decoded as `Int`, as the audited payload does. The audit lists the float/int question as
  uncertain; no live server was checked.
- A 404 whose body has `{"_tag":"LocationNotFoundError"}` means the scoped folder is gone; it is not a
  generic 404 and is not retried.

## Events

`GET /api/event` is one `data:` line per event plus `: heartbeat` comments. The parser is general (CRLF, CR,
multi-line data, unknown fields) but the bound and semantics are the audited ones: 16 MiB per frame, unknown
types skipped without decoding data, `_tag` frames fail the connection, EOF is an error.

| Type | Swift event | Status |
| --- | --- | --- |
| `server.connected` | `.connected` | implemented + tested |
| `session.execution.started` | `.executionStarted` | implemented + tested |
| `session.execution.succeeded`/`failed`/`interrupted` | `.executionEnded` (`superseded` → nil) | implemented + tested |
| `session.created`/`forked` | `.sessionCreated` (a fork is a root) | implemented + tested |
| `session.renamed`, `deleted`, `archived`, `unarchived` | `.sessionRenamed`, `.sessionDeleted`, `.sessionArchiveChanged` | implemented + tested |
| `session.moved` | `.sessionMoved`, else `.messageInvalidated` | implemented + tested |
| `session.viewed` | `.sessionViewChanged` (ms) | implemented + tested |
| `session.inbox.enqueued`/`delivery.changed`/`delivered`/`cancelled` | `.inputEnqueued`, `.inputQueueChanged`, `.inputCancelled` | implemented + tested; the admitted inbox **row** is deferred to P7 (the identity is carried) |
| `session.step.*`, `text.*`, `reasoning.*`, `tool.input.*`, `tool.*` | `.contentBatch` with `LiveContentEvent` | implemented + tested (delta coalescing, durable boundaries, part identity) |
| `session.message.content.updated`, `session.synthetic`, `session.instructions.updated`, `session.agent.selected`, `session.model.selected`, `session.permissions`, `session.retry.scheduled`, `session.compaction.*`, `session.shell.*` | `.messageInvalidated` | implemented + tested |
| `session.revert.staged`/`cleared`/`committed` | `.revertChanged` | implemented + tested |
| `permission.asked`, `form.created` | `.attentionChanged(askedSessionID:)`, `global` ignored | implemented + tested |
| `permission.replied`, `form.replied`, `form.cancelled` | `.attentionChanged(nil)` | implemented + tested |
| `shell.created` (running only), `shell.exited`, `shell.deleted` | `.shellStarted(ServerShell)`, `.shellEnded` | implemented + tested |
| `experimental.job.updated` | `.jobUpdated(ServerJob)` | implemented + tested |
| `project.updated` | `.projectUpdated(ServerProject)` | implemented + tested |
| `model.updated`, `provider.updated`, `agent.updated` | `.modelsChanged`, `.agentsChanged` | implemented + tested |
| any other type | ignored | implemented + tested |

Batching (`EventBatcher`): adjacent deltas for one part coalesce; a non-content event flushes the batch it
must follow; flush at 75 ms or 256 pending mutations; per-session order preserved. The downstream buffer is
bounded at 128; falling behind ends the connection with `EventStreamOverflow` so the owner reconnects and
rehydrates, rather than silently losing a delta.

Not adopted from `EventBatcher` (deliberate, recorded in `DECISIONS.md` D-23): the off-screen pressure
shedding and the Markdown pre-projection hooks. Both exist to protect a transcript reducer that this phase
does not have; they belong with P8, where they can be measured.

## Authentication and pairing

| Behaviour | Audited source | Swift | Status |
| --- | --- | --- | --- |
| Payload forms: JSON, `https://opencode.ai/pair#…`, `opencode(-ios)://pair?…`, one `/auth/connect/{code}` link | `OpenCodePairingLink.kt` (`5e4b4219`, 2026-11-16) | `PairingLink` | implemented + tested |
| Code is base64url and non-empty | same | `PairingLink.isValidCode` | implemented + tested |
| Every address: HTTP(S), host, no credentials/query/fragment, empty or `/` path, port 1–65535; one bad address rejects the code | same, `internal/Urls.kt` | `ServerOrigin.parse` | implemented + tested |
| Parsing never redeems a one-time code | same | `PairingLink` has no transport; the client redeems separately | implemented + tested (decoding with a blocked transport contacts nothing) |
| Loopback addresses dropped when a reachable one is listed; dedup by scheme/host/port | same, `redeemOrigins` | `PairingLink.redeemOrigins` | implemented + tested |
| Non-fetching deep link for copy/share | same, `deepLinkURL` | `PairingLink.deepLinkURL` | implemented + tested (round-trip) |
| Copied/wrapped code text | `decodeCopied` | `PairingLink.decodeCopied` | implemented + tested (basic wrap case) |
| Failure copy: expired/used, unsupported, unusable address | `live/LiveConnection.kt`, `app/src/main/res/values/strings.xml` | `ServerCopy` | implemented + tested |
| Deep-link routing helpers for the shell | `isPairingScheme`, `isPairingHTTPPath`, `isPairPage` | `PairingLink` | implemented (used by P5) |

Copy differences worth keeping visible: the audited `PROTOCOL.md` (written at iOS `4fb5e0e`) quotes the
expired-code copy as “Run `opencode pair` again and scan the new code.”; current `dev` says “Run
`opencode pair --remote` again.” This migration uses current `dev`.

## Decoding and errors

- `OpenCodeClientError` carries typed facts (status, transport failure, attempts, ambiguity, location-gone,
  unsupported, decode feature, stream failures) and no message text. Copy comes from `ServerCopy` at the
  edge, so a log can never gain an address, credential or server sentence.
- Retry classification reads those facts, never a string.
- A transport failure with no status maps `URLError` codes to `notSent`/`interrupted`/`timedOut`; unknown
  errors are `unreachable` and permanent.
- The app never logs a body. `AppLog` publishes only event names and numeric/boolean fields; request paths,
  codes and addresses are not logged.
