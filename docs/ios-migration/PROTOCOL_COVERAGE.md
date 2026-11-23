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
| One HTTP client per server, one retry layer per request | `OpenCodeTransport.kt` (`f79a895e`, 2026-11-14), `live/LiveTransport.kt` | `OpenCodeCore/Transport/{HTTPTransport,URLSessionTransport}.swift` | implemented — one shared request `URLSession` for the transport's lifetime and one per stream connection (D-26), ephemeral, no cookies or cache; every client call goes through `NetworkRetry` once |
| `Accept: application/json`; `Content-Type` only with a body | `live/LiveTransport.kt` | `OpenCodeServer/Address/OpenCodeServer.swift` (`request(path:…)`) | implemented — caller supplies the header; JSON bodies are encoded by the caller |
| Basic auth from the pairing token; username defaults to `opencode` | `OpenCodeServer.kt` | `OpenCodeServer.basicAuthorization`, `.wireHeaders` | implemented + tested |
| `location[directory]` query, escaped as `location%5Bdirectory%5D` | `internal/Urls.kt` (`5fa3aab0`, 2026-10-24) | `OpenCodeServer.endpoint(path:query:)`, percent encoders | implemented + tested (path and query encoding, `/` kept, `[` `]` escaped) |
| Timeouts: default 10 s; probe 3.5 s; pairing redeem 15 s; event read 90 s | `live/LiveTransport.kt`, `ServerLink.kt` | `HTTPRequest.timeout`, call sites | implemented for the routes above; per-route long timeouts listed below |
| Redirect control per call | `withTimeout(followsRedirects)` | `HTTPRedirectPolicy`, `HTTPRedirectRule` | implemented — rule tested, and the real `URLSession` delegate tested against the loopback fixture server |
| Credentials never leave their origin on a redirect | audited in code comments; no test | `HTTPRedirectRule`, `RedirectGuard` | implemented + tested twice: the pure rule, and a real cross-origin redirect that the target never sees |
| Cleartext policy: private, overlay and local names only | `TransportSecurity.kt` (`f79a895e`) | `OpenCodeCore/Network/HostAddress.swift` (`TransportSecurity`) | implemented + tested (RFC 1918, CGNAT, link-local, ULA, `.local`, unqualified, `ts.net`/`netbird*`/`home.arpa`/`internal`) |
| ATS, local-network permission | not an Android concept | `ios/OpenCode/Info.plist` | implemented: `NSAllowsLocalNetworking`, per-domain cleartext exceptions for the overlay names, `NSLocalNetworkUsageDescription`; no global ATS disable |
| Five-attempt request policy, send/stream/wait presets, equal jitter, retry window, `Retry-After` cap | `retry/NetworkRetry.kt` (`f79a895e`) | `OpenCodeServer/Retry/{RetryPolicy,NetworkRetry}.swift` | implemented + tested (ceiling, window, attempts, offline wait, `Retry-After` seconds/date, cap) |
| Unsafe requests resent only when provably unsent | `RequestIdempotency`, `retryVerdict` | same | implemented + tested (interrupted unsafe write sent once; `notSent` retried; 408/429/503 retried) |
| Cancellation is never a reachability failure | `retryVerdict` | `NetworkRetry.run`, transport delegate | implemented + tested |
| Under tests a request is sent once unless a policy is set | `NetworkRetry.currentPolicy` | `OpenCodeClient.live(…, policy: .once)` | implemented — the test factory defaults to `.once` |
| Offline detection and a network-path wait | `retry/NetworkPath.kt` | `NetworkPathClient`, `NetworkPathRetry` | implemented — one `NWPathMonitor`, injected updates, offline wait; P5 reconnects on a satisfied path |
| Alternate-origin routing between candidate addresses | `retry/ServerLink.kt`, `ServerContact.kt` | `OpenCodeServer.candidateURLs`, `ServerLink` | implemented — every candidate probed once with a preferred head start; the winning address is used for the connection |

## REST routes

Every response the adopted routes read is decoded with the synthesized `Codable` rules the audited codec
uses: unknown keys ignored, absent optionals nil, a present wrong type rejects the payload.

| Method | Path | Audited source | Swift | Status |
| --- | --- | --- | --- | --- |
| GET | `/api/info` | `live/LiveConnection.kt` `requestHealth` (`5e4b4219`, 2026-11-16), `ServerInfoPayload` | `ServerInfo`, `Operations.health` | implemented + tested: 3.5 s, one attempt, redirects refused, address-identification rule |
| GET | `/auth/connect/{code}` | `live/LiveConnection.kt` `requestRedeemPairing` | `Operations.redeemPairing` | implemented + tested: one GET per candidate, no `Authorization`, 15 s, `.unsafe`, redirects refused, 401/404 copy |
| GET | `/api/project` | `live/LiveFamily.kt` | `Operations.projects`, `ProjectPayload` | implemented + tested: bare array, display-name and repository-slug rules |
| GET | `/api/session` | `live/LiveSessions.kt` `requestSessionPage`, `requestRootSessions` (`8566441f`, 2026-11-17) | `Operations.sessionPage` | implemented + tested: first page (`limit,parentID=null,archived=false,order=desc`), `search`, cursor page, archived/child filter, empty-page end |
| GET | `/api/session/{id}` | same | `Operations.getSession` | implemented + tested: `time.updated` ms, title placeholder, archive, revert, notification metadata |
| GET | `/api/session/active` | `live/LiveSessions.kt`, `live/LiveFamily.kt` | `Operations.activeSessionIDs`, `Operations.sessionIsActive` | implemented + tested: map envelope; the single-session check is the Stop settlement read |
| GET | `/api/event` | `live/LiveEvents.kt` (`4c1e0054`, 2026-11-20) | `EventStream`, `EventStreamRunner` | implemented + tested: SSE, batching, watchdog, 401 stop, reconnect |
| GET | `/api/session/{id}/message?order=desc&limit=N` | `live/LiveTranscript.kt` (`requestTranscript`) | `Operations.transcript`, `TranscriptDecoder.page` | implemented + tested: newest window (30), oldest-first rows, cursor, all audited message types |
| GET | `/api/session/{id}/message?limit=N&cursor=…` | same (`requestHistoryPage`) | `Operations.transcriptHistory` | implemented + tested: 80 per page, 20 s, `order=desc` when the edge is unknown, same-cursor loop rejected |
| GET | `/api/session/{id}/message/{messageID}` | same (`requestMessage`) | `Operations.message` | implemented + tested: ordered rows, strict decode |
| POST | `/api/session/{id}/prompt` (30 s, idempotent by message id) | `live/LivePrompts.kt` | `PromptBody` (core fields only) | modelled + encoded in tests; call site deferred to P9 (composer) |
| POST | `/api/session/{id}/interrupt?resume=true` | `live/LiveSessions.kt` `requestInterrupt` | `Operations.interruptSession` | implemented + tested: `{interrupted}`, unsafe, one attempt per caller-owned retry; ambiguity reads active/inbox before another try |
| POST | `/api/session` (create; idempotent only with a client id) | `live/LiveSessions.kt` `requestCreateSession` | — | deferred to P11 (What's New Try It) |
| PATCH | `/api/session/{id}` (rename; empty title is unsafe, 60 s) | same `requestRenameSession` | — | deferred to P9 (session menu) |
| PATCH | `/api/session/{id}` (archive/unarchive, idempotent) | same `requestSetArchived` | — | deferred to P11 (the Android archived page is not inherited) |
| DELETE | `/api/session/{id}` | same `requestDeleteSession` | `Operations.deleteSession` | implemented + tested (P6 Home delete; unsafe by default, one call) |
| POST | `/api/session/{id}/move` (unsafe, 15 s) | same `requestMoveSession` | — | deferred (not in P7 scope) |
| POST | `/api/session/{id}/view` (idempotent watermark) | same `requestViewSession` | `Operations.viewSession` | implemented + tested (P6 read receipts; body `{idle}`, idempotent, one retry layer) |
| POST | `/api/session/{id}/fork` | same `requestForkSession` | — | deferred (not in P7 scope) |
| POST | `/api/session/{id}/compact` | same `requestCompactSession` | — | deferred (not in P7 scope) |
| POST | `/api/session/{id}/revert/stage`, `DELETE …/revert` | same | — | deferred (not in P7 scope) |
| POST | `/api/session/{id}/background` | same | — | deferred (not in P7 scope) |
| GET | `/api/experimental/session/{id}/export` (60 s) | same `requestExportSession` | — | deferred (not in P7 scope) |
| POST | `/api/experimental/session/{id}/wait` (25 s poll, idempotent) | same `requestWaitForIdle` | — | deferred to P9: the send path owns the wait loop; P8 settlement reads do not poll |
| GET | `/api/session?parentID={id}&order=desc&limit=100` | `live/LiveFamily.kt` `requestSessionFamily` | `Operations.sessionFamily` | implemented + tested: BFS, six pages in flight, 100-session cap, cycle/dedupe, bounded running ancestry |
| GET | `/api/session/{id}/inbox` | `live/LivePrompts.kt` | `Operations.pendingInputs` | implemented + tested: user/synthetic/compaction rows, delivery steer/queue. The composer sheet is P9 |
| PATCH | `/api/session/{id}/inbox/{inputID}` (unsafe; 409 or read-back settles) | same | `Operations.setPendingInputDelivery` | implemented + tested: reads the inbox back after ambiguity or 409; stranded steer queues then steers |
| DELETE | `/api/session/{id}/inbox/{inputID}` (idempotent) | same | — | deferred to P9 (the composer owns cancel) |
| GET | `/api/permission/request`, `/api/form` (60 s, location-scoped) | `live/LiveRequests.kt` | `Operations.attentionSessionIDs`, `Operations.pendingRequests` | implemented + tested: Home keeps the loose root read; P7 decodes full models, filters by family, keeps `global` forms, and treats a failed read as a failed snapshot |
| POST | `/api/session/{id}/permission/{requestID}/reply` | same | `Operations.replyPermission` | implemented + tested: `{decision, message?}`, only a denial carries a reason, Always requires save patterns |
| POST | `/api/session/{id}/form/{formID}/reply` | same | `Operations.replyForm` | implemented + tested: validates only active answers, read-back after ambiguous/409, one resend while pending, typed conflict |
| DELETE | `/api/session/{id}/form/{formID}` | same | `Operations.cancelForm` | implemented + tested: optional reason, same settlement rules |
| GET | `/api/session/{id}/form/{formID}` | same | `Operations.formState` | implemented + tested: `{data:{state}}`, status/answer/message |
| GET | `/api/shell?location[directory]` | `live/LiveRequests.kt` | `Operations.runningShells` | implemented + tested: running only, location-scoped |
| GET | `/api/shell/{id}` | same | `Operations.shell` | implemented + tested: one shell, unknown status reads as exited |
| GET | `/api/shell/{id}/output?cursor&limit` (20 s) | same | `Operations.shellOutput` | implemented + tested: 64 KiB pages, absolute cursors, 404 marks unavailable |
| DELETE | `/api/shell/{id}` | same | `Operations.stopShell` | implemented + tested: drains output first, unsafe |
| GET | `/api/experimental/job?sessionID&descendants=true&status=running` | same | `Operations.runningJobs` | implemented + tested: running jobs only |
| POST | `/api/experimental/job/{jobID}/cancel` | same | `Operations.cancelJob` | implemented + tested: idempotent |
| GET | `/api/model`, `/api/model/default` | `live/LiveCatalog.kt` | `ModelRef` only | deferred to P9/P11 |
| GET | `/api/agent`, `/api/skill`, `/api/command`, `/api/plugin`, `/api/mcp`, `/api/integration` | `live/LiveCatalog.kt` | — | deferred to P9/P11 |
| GET | `/api/fs/list`, `/api/fs/find`, `/api/fs/read/{rel}` | `live/LiveFiles.kt` | — | deferred to P9/P10 |
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

## Stream lifecycle

| Behaviour | Audited source | Swift | Status |
| --- | --- | --- | --- |
| Startup cancellation before, during or after continuation registration | `live/LiveEvents.kt` (audited loop), no explicit iOS test | `StreamReceiver` state machine, `URLSessionTransport.open` | implemented + tested: pre-cancelled open, cancellation inside session creation, and cancellation while headers are pending (loopback) |
| Connect deadline covers response headers | audited `EventStreamWatchdog` connect deadline | `EventStream.openWithDeadline` | implemented + tested: a server that accepts and withholds headers fails by the deadline, and its socket closes |
| Rejected response closes the connection | implied by `use {}` in the audited stream | `EventStream.connect` (`response.close()`), `HTTPStream.close` | implemented + tested (401/503, loopback 401) |
| Consumer shutdown closes the request | audited `awaitClose { call.cancel() }` | `EventConnection.close`, channel close handler | implemented + tested: a cancelled consumer and an explicit close both close the loopback socket |
| Overflow is an explicit signal for REST resynchronization | audited `EventStreamOverflow` + reconnect loop | `EventStreamOverflow`, `EventStreamRunner.onResynchronize` | implemented + tested: overflow closes the connection, calls the callback once, reconnects, and resumes events |
| Overflow recovery is bounded | audited stream-overflow policy (D-27) | `maximumConsecutiveOverflows`, `RetryPolicy.streamOverflow` | implemented + tested: three consecutive overflows with a limit of two end the stream; repeated connect-then-overflow cycles reach the limit too (D-29) |
| Overflow protection resets only after healthy consumption | new bound (D-29) | `healthyResetWindow`, `healthyResetEvents` | implemented + tested: a handshake alone never resets; content past the window does |
| Transport chunk-buffer overflow is recoverable | new typed outcome (D-30) | `TransportError.streamOverflow` → `.streamOverflow` | implemented + tested: real loopback buffer overflow is typed; the runner resynchronizes and reconnects |
| Reconnect closes the previous connection first | audited loop's connection ownership | `EventStreamRunner` (explicit close before resync, defer close otherwise) | implemented + tested |
| A web page is not API data | not audited (diagnostic gap) | `.incompatibleAPI` (D-31) | implemented + tested with real content types; 401 stays an auth failure |

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
| `session.inbox.enqueued`/`delivery.changed`/`delivered`/`cancelled` | `.inputEnqueued`, `.inputQueueChanged`, `.inputCancelled` | implemented + tested; P7 re-reads the inbox and the session screen shows steering/queued rows. The composer sheet is P9 |
| `session.step.*`, `text.*`, `reasoning.*`, `tool.input.*`, `tool.*` | `.contentBatch` with `LiveContentEvent` | implemented + tested (delta coalescing, durable boundaries, part identity); P8 projects text/tool events into transcript rows, reasoning adds no row |
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
hydrates from REST, rather than silently losing a delta. `EventStreamRunner.onResynchronize` is that
hand-off; recovery is bounded (D-27).

P8 adopts the pressure policy (D-61) as **coalescing, bounded replay and explicit recovery**:
`EventBatcher` merges adjacent deltas for one part per 75 ms flush, the downstream buffer stays bounded
(overflow reconnects and rehydrates), and Markdown parses only visible rows off the main actor into a
bounded cache (256 entries / 4 MiB) cleared on a memory warning. Events racing an authoritative read are
retained up to 512 separate batches; crossing that bound discards the partial replay and stores persistent
`SessionRecovery`. Its authoritative read preserves a durable boundary's 200 ms settlement delay, survives
failed attempts and clears only after a coherent transcript read. Recovery is bounded to one immediate
attempt plus one delayed retry, then a manual retry/reconnect through the same coordinator. The projection is
never published as complete after that signal, and durable REST remains the source of truth. `session.message.content.updated`
and the other invalidating events trigger that same read rather than being ignored.

## Compatible server requirements

The app expects an OpenCode V2 server that serves the audited JSON routes. Checked read-only against
`opencode serve` 0.0.0-dev-202611170722 (the newest `dev` build available when this phase ran):

| Requirement | Evidence |
| --- | --- |
| `GET /api/info` returns JSON `{version, pid, urls?}` | that build has no such route; authenticated requests fall through to its web shell (200 `text/html`) |
| `GET /api/project` returns the bare project array with `canonical` | that build exposes `/project` (JSON) with a different shape (`worktree`, no `canonical`), not `/api/project` |
| `GET /api/session`, `/api/session/active`, `/api/event` | present and JSON/SSE in that build, and exercised by the live smoke |
| Basic auth | present: unauthenticated `/api/session` answers `401` JSON `UnauthorizedError`, and the live smoke authenticated successfully |

Do not silently remap `/api/project` to `/project` or treat the web shell as data: neither matches the
audited contract. A connection attempt that lands on an HTML page now fails as
`.incompatibleAPI` (D-31), which is distinct from a rejected password and from an unreachable host.

P5 uses `health` (`/api/info`), `projects` (`/api/project`) and `events` (`/api/event`). P6 adds
`/api/session`, `/api/session/active`, `/api/session/{id}/view`, `DELETE /api/session/{id}` and the two
attention reads. P7 adds the child family page, interrupt, the full request models/replies, inbox delivery,
shells/output/stop and jobs/cancel. A compatible fixture serves the connection routes through the real `URLSession` stack in
`LocalFixtureServerTests.compatibleFixtureConnection`; Home runs against the deterministic in-app fixture
because no live V2 build with `/api/info` and `/api/project` was available. That incompatible outcome is
preserved, not remapped.

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
