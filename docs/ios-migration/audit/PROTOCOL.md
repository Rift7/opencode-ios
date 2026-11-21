# PROTOCOL — OpenCode mobile ↔ server contract

Two evidence streams, kept separate on purpose:

- **A. Current dev (authoritative for behaviour).** Kotlin `server/` module at `dev = 7358160e808fb1870eeb20f5da8df832667019d1`. Paths below are relative to `server/src/main/kotlin/ai/opencode/server/`.
- **B. iOS-era description (evidence, may be stale).** `docs/port/explore/protocol.md` on `glass-look`, written against iOS `4fb5e0e` (2026-10-07), plus per-file rows in `docs/parity/server.md` synced to iOS `01eef583`.

Where A and B disagree, A wins for current behaviour; B is only used to recover iOS naming, ordering and copy that Kotlin changed.

---

## 1. Transport

From `OpenCodeTransport.kt`, `live/LiveTransport.kt`, `TransportSecurity.kt`, `internal/Urls.kt`:

- One HTTP client per server; all requests go through `OpenCodeClient` + `NetworkRetry`. REST is authoritative; SSE only invalidates/projects.
- `Accept: application/json` on JSON reads; `Content-Type` only when there is a body.
- `Authorization: Basic base64(username:password)` when a password/pairing token exists. Username defaults to `opencode`.
- Default request timeout 10 s, with per-call overrides (long: `wait` 600 s, export 60 s, upload 120 s, location-scoped request reads 60 s, SSE read timeout 90 s).
- Non-2xx becomes `OpenCodeClientError` (`OpenCodeClientError.kt`) carrying status + decoded error body; transport failure yields a nil status and the user-facing "Couldn’t reach the OpenCode server".
- Query parameter for directory scoping is literally `location[directory]`; a bare `directory` is ignored (per B; A's `internal/Urls.kt` encodes it).
- Server identity: `ServerID.kt` derives a stable id; `ServerSharedKeys.kt` holds server-typed shared keys; `OpenCodeServer.kt` holds the address set. Each saved server can have multiple candidate URLs (`ServerLink.kt`, `retry/ServerContact.kt`).

## 2. Authentication and pairing

- Pairing payload (QR / `opencode pair`): `{"code": "...", "urls": [...]}`. Code is base64url `[A-Za-z0-9_-]`; every URL must be `http(s)`, have a host, no credentials/query/fragment, empty or `/` path, port 1–65535; one malformed URL rejects the payload.
- Redeem: `GET {origin}/auth/connect/{code}` **without** Authorization, 5 s, returns `{token}`; the token becomes the Basic-auth password. All candidate URLs are tried; first success wins and returned `urls` become alternates.
- Failure copy (B, preserve wording): expired/used → "This pairing code has expired or was already used. Run `opencode pair` again and scan the new code."; 404 → "This server doesn't support pairing links. Update OpenCode on your computer, or enter the server manually."; all-loopback addresses are refused with the `opencode service set hostname 0.0.0.0` instruction.
- Legacy deep link: exactly `/auth/connect/{code}`.
- Manual entry also supported (scheme optional, cleartext allowed for local addresses by policy in `TransportSecurity.kt`).
- Credentials belong in Keychain in the new app; never log them or the address.

## 3. Routes observed in current dev

Extracted from the Kotlin sources (`OpenCodeClient*.kt`, `live/Live*.kt`). "§" marks routes also named in B.

| Method | Path | Notes |
| --- | --- | --- |
| GET | `/api/info` § | `{version, pid}` plus optional `urls`, `paths.tmp` |
| GET | `/auth/connect/{code}` § | token redeem, no auth |
| GET | `/api/project` § | bare array `[{id, canonical, name?}]` |
| GET | `/api/session?parentID=…&order=desc&limit=…` § | `{data:[Session]}`; roots use `parentID=null`, limit 50; family BFS uses 100 |
| POST | `/api/session` § | `{location:{directory}}` |
| GET | `/api/session/{id}` § | `{data: Session}` |
| PATCH | `/api/session/{id}` § | rename `{title}`; 60 s when title empty |
| DELETE | `/api/session/{id}` § | |
| DELETE | `/api/session/{id}` (archive) / `archived` list | Android-only archived sessions (`server.md`) |
| GET | `/api/session/active` § | `{data:{<sessionID>:{type}}}` |
| GET | `/api/session/{id}/message?order=desc&limit=N` § | newest-first, client reverses |
| GET | `/api/session/{id}/message?limit=N&cursor=…` § | history paging |
| GET | `/api/session/{id}/message/{messageID}` § | single-message reconcile |
| POST | `/api/session/{id}/message` § | message write path used by some ports |
| POST | `/api/session/{id}/prompt` § | `PromptBody`, 30 s |
| POST | `/api/session/{id}/interrupt` § | |
| POST | `/api/session/{id}/compact` § | `{}` |
| POST | `/api/session/{id}/fork` § | `{data: Session}` |
| GET | `/api/experimental/session/{id}/export` § | raw bytes, 60 s |
| GET | `/api/experimental/session/{id}/wait` § | 600 s |
| POST | `/api/session/{id}/model` § | `{model:{id, providerID}}` |
| POST | `/api/session/{id}/agent` | agent selection |
| POST | `/api/session/{id}/command` | slash commands |
| POST | `/api/session/{id}/view` § | `{idle: Int64}` ms watermark |
| POST | `/api/session/{id}/move` | move to project/directory |
| POST | `/api/session/{id}/background` § | move run to background |
| POST | `/api/session/{id}/revert`, `/revert/stage` | revert workflow |
| GET | `/api/session/{id}/inbox` § | queued prompts |
| PATCH | `/api/session/{id}/inbox/{inputID}` § | `{delivery: "steer"\|"queue"}` |
| DELETE | `/api/session/{id}/inbox/{inputID}` § | cancel queued prompt |
| GET | `/api/permission/request`, `/api/form` § | `location[directory]`, 60 s |
| POST | `/api/session/{id}/permission/{requestID}/reply` § | `{decision:"once"\|"always"\|"reject"}` |
| POST | `/api/session/{id}/form/{formID}/reply` § | `{answer:{key: …}}` |
| GET/POST | `/api/session/{id}/form/{formID}` | form read/reply |
| GET | `/api/shell?location[directory]` § | running shells, 20 s |
| GET | `/api/shell/{id}`, `/output?cursor&limit` § | output page 64 KiB |
| DELETE | `/api/shell/{id}` § | stop shell |
| GET | `/api/model`, `/api/model/default` § | catalogue; only `enabled && status=="active"` |
| GET | `/api/agent`, `/api/skill`, `/api/plugin`, `/api/mcp`, `/api/command`, `/api/form` | catalogues |
| GET | `/api/integration`, `/api/integration/{id}`, `/…/connect/oauth` | integrations/OAuth |
| GET | `/api/fs/list`, `/api/fs/find`, `/api/fs/read/{rel}` § | file system |
| POST | `/api/experimental/fs/write` § | upload octets to `paths.tmp/uploads/{uuid}/{name}` |
| GET | `/api/experimental/media/{hash}` | media blob by content hash |
| GET | `/api/experimental/job`, `POST …/{jobID}/cancel` | background jobs |
| POST | `/api/experimental/client-mcp` | client tools socket |
| POST | `/api/rpc/mobile-notifications/pair` | push pairing (FCM relay; incomplete server-side) |
| GET | `/api/event` § | SSE |

Discrepancies to keep visible: `/api/experimental/media/*`, `client-mcp`, mobile-notifications and jobs appear in dev but not in the iOS-era doc (they are newer or Android-side); the archived-session and quoted-comment flows are Android-only additions per `docs/parity/server.md`.

## 4. Prompt body

```
{ "id": "msg_<UPPERCASE-UUID-no-hyphens>",
  "text": "typed text\nAttached file: `/abs/path`",
  "files": [{"uri":"data:image/png;base64,…","name":"optional"}],
  "delivery": "steer"|"queue",            // omitted when nil
  "metadata": {"displayText": "...", "comments": [], "attachments":[{"name","mime","path"}]} }
```

`metadata` only when at least one path attachment exists; `comments: []` always present because the desktop reads `displayText` only when comments is an array. Display strips the exact `Attached file: ` lines rather than trusting `displayText`.

## 5. SSE

`GET /api/event`, `Accept: text/event-stream`, Basic auth, dedicated connection, **90 s read timeout reset by `: heartbeat`** (~15 s), no `Last-Event-ID` and no resume. One JSON value per `data:` line; `event:`/`id:` ignored; >16 MiB line throws; unknown types skipped; EOF throws "The event stream ended."; **401 stops reconnecting**.

Event names present in current dev (`OpenCodeServerEvent.kt`, `live/LiveEvents.kt`, `EventBatcher.kt`):

```
server.connected
permission.asked | permission.replied | permission.rejected
session.created | renamed | deleted | archived | unarchived | moved | viewed | forked
session.execution.started | .succeeded | .failed | .interrupted
session.step.started | .streamed | .ended | .failed
session.text.started | .delta | .ended
session.reasoning.started | .delta | .ended
session.tool.input.started | .delta | .ended
session.tool.called | .progress | .success | .failed
session.message.content.updated
session.synthetic
session.agent.selected | session.model.selected
session.instructions.updated
session.permissions
session.retry.scheduled
session.compaction.started | .ended | .failed
session.revert.staged | .committed | .cleared
session.inbox.enqueued | .delivered | .delivery.changed | .cancelled
session.shell.started | .ended
```

Coalescing (`EventBatcher`): non-content events flush pending content then yield; content deltas merge only when adjacent and from the same part; flush at 75 ms or 256 pending; per-session order preserved.

Semantics that must survive the rebuild:
- `session.shell.*` invalidates the transcript; `shell.created`/`exited`/`deleted` drive the background capsule.
- Inbox `enqueued`/`delivery.changed`/`cancelled` re-read the inbox; `delivered` also invalidates; promotion is never inferred from the event payload.
- Delta text is never replayed onto REST reads; a settled read replaces the streaming projection.
- A single 401 kills the reconnect loop; other failures back off 1/2/4/8/15 s with stable jitter.

## 6. Models and decoding rules

- `SessionPayload`: `time.updated` is Unix **ms as a JSON number**; `time.idle`/`time.viewed` are Int64 ms echoed to `/view`; blank title → "Untitled session"; `location.directory` required; `cost` is per-session USD.
- `ShellInfo`: `metadata.sessionID`, `metadata.background == true` means user-invoked `!`; unknown status → `exited`; `exit` decoded Double→Int; event-created shells are not listable.
- Transcript projection: user text/images/files split into separate rows; assistant text ordinal counts empty parts; tool rows keyed by `part.id`; reasoning is dropped from the mobile transcript; message `error` becomes an info row; shell and skill become tool rows; run error text "Run failed: {type} — {human}".
- Tool images: only `data:` URIs with `image/*`; caps 16 images, 20 MB each, 32 MB total.
- Context usage: newest-first over 8 messages; a completed compaction makes it empty; token totals sum `input + cache.read + cache.write` for input and `output + reasoning` for output.
- Forms: strict decode (one unknown enum fails the list); field types `string|number|integer|boolean|multiselect|external`; `default` decodes into `defaultValue`; progressive visibility clears hidden answers; external fields must be `true`; `global` forms belong to the open session and do not light the drawer.
- A failed permission/form read is a **failed snapshot**, never "no pending requests".

## 7. Retry, reconnect and recovery

`retry/NetworkRetry.kt`, `retry/NetworkPath.kt`, `retry/ServerContact.kt`:
- One retry layer for every request; REST reads retried on transport failure, writes only where idempotent (`POST /view`, `/wait`).
- Under tests, requests are sent once unless a policy is set.
- Connection is stateful in the app layer: candidates tried in order; `server.connected` adopts the answering address and resets backoff; timeout after a live connect is a stall; two losses without a connect → disconnected.
- Watchdog intervals (from B): 20 s healthy-with-content, 3 s while running without a proven projection, else 30 s, plus deterministic jitter; pending-request and inbox polls 2 s until healthy then 12 s.
- Settlement (from B): durable boundaries (`*.ended`, `tool.input.ended`, tool called/succeeded/failed) sleep 200 ms then re-read the single message; otherwise a 30-message page plus `getSession`.
- Sending: the prompt POST must outlive the screen; a user retry mints a **new** `msg_` id.

## 8. Errors and failure reporting

- Copy that must be preserved: "The server rejected these credentials." (401); "The server returned HTTP {status}."; "Couldn’t reach the OpenCode server"; "The {name} does not match the current OpenCode V2 contract."; decode failures "The {name} could not be encoded."; uploads unsupported → "This server doesn’t support file attachments. Update OpenCode on your computer."
- Diagnostics categories (from B): 401 / 404 / `server(n)` / timeout / offline / cancelled / transport, with POSIX `ETIMEDOUT` as timeout and `ENOTCONN, ECONNRESET, ECONNABORTED, EPIPE, ENETDOWN, ENETUNREACH, EHOSTDOWN, EHOSTUNREACH` as offline.
- Copyable connection report format (B): header "OpenCode connection error"; `App: OpenCode {version} ({build})`; `Report generated at: {ISO8601}`; `Phase: Pair|Connect|Load sessions`; `Server: {host[:port]}`; `Attempt: {n}`; `Message:`; `safeTarget` keeps only `[A-Za-z0-9.-:\[\]]`.
- Cancellation must be swallowed by `Task.isCancelled` and never surfaced as a reachability failure.

## 9. Version drift / uncertainty

- B was written at iOS `4fb5e0e`; current dev has since added archived sessions, jobs, media hashes, integrations, client tools and mobile-notification pairing. Those have no iOS-era description; treat their *Android* behaviour as the baseline only where they are user-visible on both platforms.
- Not recoverable: whether the server accepts host-candidate-less WebRTC offers (spike explicitly untested); `/api/fs/read` range support; whether `/api/info.pid` is int or float in every server version; redirect handling.
- `docs/parity/server.md` records `liveServerReadContract` as opt-in and **not run** in CI; this audit did not run it either.
