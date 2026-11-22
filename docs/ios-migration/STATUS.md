# iOS migration — status

## Baseline

| Item | Value |
| --- | --- |
| Integration branch | `ios` |
| Base commit | `7358160e808fb1870eeb20f5da8df832667019d1` (`origin/dev`) |
| Verified against | audit of 2026-11-21 (`docs/ios-migration/audit/AUDIT.md`) |
| `ios` head when P4 started | `d0fdf2f5cc3c37b0e0fab6146a49469f0ff86540` (PR #2, core foundation) |
| P4 branch | `ios-networking`, created from that `ios` head (draft PR: `Rift7/opencode-ios#3`) |
| Worktree | a separate worktree; the Android checkout is untouched |

`git fetch origin` then `git merge-base --is-ancestor d0fdf2f5 origin/ios` confirmed PR #2's merge was in
`origin/ios` before the branch was created. The merged tree contains `ios/OpenCodeKit` with the P3 core
targets and tests; they were run as the phase baseline before any new file was added.

## Phase status

| Phase | Scope | Status |
| --- | --- | --- |
| 1 | Read-only reconstruction audit | complete (`docs/ios-migration/audit/`) |
| 2 | `ios` branch, baseline, scaffold and gate | complete — `143d8f86` (PR #1) |
| 3 | Core: store, dependencies, sharing, tokens, logging, haptics | complete — merged into `ios` as `d0fdf2f5` (PR #2) |
| 4 | Server: transport, retry, models, SSE, pairing | **complete on `ios-networking`**, review corrections applied; draft PR open |
| 5 | App shell: launch, connection, pairing, reconnect | scaffold only; next |
| 6 | Home, drawer, projects, Catch Up, What's New | not started |
| 7 | Session, subagents, background work, request review | not started |
| 8 | Transcript | not started |
| 9 | Composer | not started |
| 10 | Media | not started |
| 11 | Settings, experiments, diagnostics, onboarding | not started |
| 12 | System integrations | not started |
| 13 | Voice (Experimental, off) | not started |
| 14 | Hardening | not started |

## Phase 4 — what landed

| Area | New path | Gate |
| --- | --- | --- |
| Host classification and cleartext policy | `OpenCodeKit/Sources/OpenCodeCore/Network/HostAddress.swift` | `OpenCodeServerTests/ServerAddressTests.swift` |
| Injectable monotonic clock | `OpenCodeKit/Sources/OpenCodeCore/Dependencies/ClockClient.swift` | `DependencyIsolationTests`, retry tests |
| Bounded pull channel | `OpenCodeKit/Sources/OpenCodeCore/Concurrency/BoundedChannel.swift` | `OpenCodeCoreTests/BoundedChannelTests.swift` |
| Request/response/stream seam, redirect rule | `OpenCodeKit/Sources/OpenCodeCore/Transport/{HTTPTransport,URLSessionTransport}.swift` | `TransportTests`, `RedirectRuleTests`, `LocalFixtureServerTests` |
| Server origin, saved server, endpoint encoding | `OpenCodeKit/Sources/OpenCodeServer/Address/{ServerOrigin,OpenCodeServer}.swift` | `ServerAddressTests` |
| Pairing parse and candidates | `OpenCodeKit/Sources/OpenCodeServer/Pairing/PairingLink.swift` | `PairingLinkTests`, loopback pairing redirect test |
| Wire models | `OpenCodeKit/Sources/OpenCodeServer/Models/*.swift` | client and event-suite decode tests |
| Central retry policy | `OpenCodeKit/Sources/OpenCodeServer/Retry/{RetryPolicy,NetworkRetry}.swift` | `RetryTests` |
| Typed errors and copy | `OpenCodeKit/Sources/OpenCodeServer/Client/{OpenCodeClientError,ServerCopy}.swift` | client tests assert status, copy, log summary |
| SSE parsing, batching, connection lifecycle | `OpenCodeKit/Sources/OpenCodeServer/Events/*.swift` | `SSEParserTests`, `ServerEventDecoderTests`, `EventBatcherTests`, `EventStreamTests`, `LocalFixtureServerTests` |
| Client dependency | `OpenCodeKit/Sources/OpenCodeServer/Client/OpenCodeClient.swift` | `OpenCodeClientTests` |
| Loopback fixture server | `OpenCodeKit/Sources/OpenCodeTestSupport/LocalHTTPServer.swift` | `LocalFixtureServerTests` |
| ATS and local-network declaration | `ios/OpenCode/Info.plist`, `ios/project.yml` | device run (below) |
| DEBUG device probes | `ios/OpenCode/App/DeviceProbes.swift` | device run (below) |
| Live read-only smoke (opt-in) | `OpenCodeKit/Tests/OpenCodeServerTests/LiveServerTests.swift` | run once against a local server (below) |

Adopted values and their freshness (all against `dev = 7358160e`):

| New behaviour | Android source | File last changed | Treatment |
| --- | --- | --- | --- |
| Cleartext policy (RFC 1918, CGNAT, link-local, ULA, `.local`, overlay names) | `server/.../TransportSecurity.kt` | `f79a895e`, 2026-11-14 | values adopted; ATS is the native equivalent of the manifest declaration |
| Retry presets, equal jitter, classification, `Retry-After` | `server/.../retry/NetworkRetry.kt` | `f79a895e`, 2026-11-14 | policies adopted; clock and task structure native (D-21) |
| Pairing forms, validation, loopback filtering, copy | `server/.../OpenCodePairingLink.kt`, `live/LiveConnection.kt` | `5e4b4219`, 2026-11-16 | adopted, including current copy |
| Session page query, filters, envelopes | `server/.../live/LiveSessions.kt` | `8566441f`, 2026-11-17 | adopted |
| Event set, decode rules, batching | `server/.../live/LiveEvents.kt`, `EventBatcher.kt` | `4c1e0054`, 2026-11-20 (events); `f79a895e` (batcher) | adopted; transcript pressure shedding deferred (D-23) |
| `location[directory]` encoding | `server/.../internal/Urls.kt` | `5fa3aab0`, 2026-10-24 | adopted, byte-for-byte expectations in tests |
| Models and optionality | `server/.../model/Models.kt`, `live/Payloads.kt` | `4c1e0054` | adopted for the modelled subset; the rest listed in `PROTOCOL_COVERAGE.md` |

No recovered iOS source file exists for these areas; every value above carries current `dev` behaviour and
is labelled a native decision, not a port.

## Review corrections (streaming)

| Finding | Correction | Regression tests |
| --- | --- | --- |
| Overflow left recovery implicit and could repeat without bound | `EventStreamOverflow` names its cause; `EventStreamRunner.onResynchronize` is called once per overflow before reconnecting (the documented REST rehydration point); overflow uses `RetryPolicy.streamOverflow` and stops after `maximumConsecutiveOverflows` (5) | overflow-then-reconnect; bounded overflows end the stream; overflow closes the prior connection |
| Startup could hang when cancellation raced continuation registration | `StreamReceiver` is a Mutex-guarded state machine; cancel before/during/after registration resumes the caller exactly once; pre-cancelled `open` throws | pre-cancelled open; cancellation inside session creation; cancellation while headers are pending |
| The connect deadline did not cover response headers | `openWithDeadline` races the whole open (connect, request, headers) against the clock and closes a late stream | withheld headers fail by the deadline and the socket closes |
| Rejected responses, consumer shutdown, overflow and reconnect could leave a connection or its tasks alive | `HTTPStream.close` and `EventConnection.close` are explicit, idempotent, and cancel the read, watchdog and session; rejected responses close before throwing; the runner closes with `defer` | 401/503 close; cancelled consumer closes the loopback socket; explicit close; close-before-reconnect |
| "One ephemeral session" did not match per-request sessions | D-26: one shared request session for the transport's lifetime, one per stream connection, each invalidated on its own lifecycle | two requests build one session; two streams build two |
| The overflow limit reset on every `server.connected` | D-29: the handshake resets only the ordinary backoff; the overflow count clears after `healthyResetWindow` with `healthyResetEvents` events beyond the handshake | repeated connect-then-overflow cycles reach the limit; content past the window clears it |
| A transport chunk-buffer overflow became permanent `.unreachable` | D-30: `TransportError.streamOverflow` is mapped to `.streamOverflow` and takes the same close → resync → bounded reconnect path | real loopback buffer overflow is typed; the runner resynchronizes and reconnects |
| An HTML page looked like a contract/decode problem | D-31: a 2xx `text/html` page is `.incompatibleAPI`, distinct from 401 and transport failures | loopback and scripted clients assert the classification and copy |

## Verified in this phase

| Command | Result |
| --- | --- |
| `swift test --package-path OpenCodeKit` | **232 tests pass**: 152 server, 66 core, 14 app (the live suite is skipped without environment variables) |
| `ios/scripts/verify.sh` | toolchain 27.2 / Swift 6.4.2 / SDK 27.2; app build succeeds; `OpenCodeTests` Swift Testing suite passes (2 tests); 4 UI tests pass; package suites pass |
| Loopback fixture suite (`LocalFixtureServerTests`) | same-origin redirect followed with credentials; cross-origin redirect refused and target untouched; pairing redirect refused (302, no auth header); withheld headers time out and close; 401 closes; cancelled consumer and explicit close stop the socket; a 256 KiB chunk stream overflows the typed chunk buffer; an HTML `/api/info` is `.incompatibleAPI` |
| Device build (iPhone Air, physical) | `xcodebuild … -destination id=<device> -allowProvisioningUpdates DEVELOPMENT_TEAM=<team> -skipMacroValidation build` succeeded with the configured development identity |
| Live read-only smoke, opt-in | `OPENCODE_LIVE_SERVER=… OPENCODE_LIVE_PASSWORD=… swift test --filter LiveServerTests` passed against `opencode serve 0.0.0-dev-202611170722` on loopback: session page, active IDs, `server.connected` over SSE, and the compatibility classification below |

## Hardware observations (separate from automated results)

Device: iPhone Air (`iPhone18,4`), iOS 27.2, debug build signed with the configured development identity.
Probes are DEBUG-only launch arguments; they print one classification line and never log an address or
credential.

| Check | Observation |
| --- | --- |
| Local-network prompt, denied | The prompt appeared on first launch; after “Don't Allow”, the probe reported `localNetwork=unreachable reason=URLError -1009` and the Mac fixture saw no request. |
| Local-network prompt, allowed | After reinstall the prompt appeared again; after “Allow”, the probe reported `localNetwork=reachable status=200` against the Mac's LAN fixture, a loopback-free private address. |
| Foreground haptics | First run: all eleven calls returned, nothing felt (System Haptics was off). After enabling Settings › Sounds & Haptics › System Haptics and holding the phone, the second run played all eleven and the observer confirmed the taps, selection tick and the three notification patterns were felt and distinguishable. |

These are observations on one device. They do not run in CI and no simulator can reproduce them.

## Live-server investigation (read-only)

Executable: the `opencode serve` binary from npm `opencode-ai@0.0.0-dev-202611170722` (the newest `dev`
tag available at the time; the absolute install path is intentionally not recorded here). Bound to
loopback with a disposable password passed by environment variable only; nothing was logged or committed.

| Probe | Result |
| --- | --- |
| `/doc` OpenAPI paths | no `/api/info`; `/api/health` present; project routes are `/project`, `/project/current`, `/project/{id}`; `/api/session`, `/api/session/active`, `/api/event` present |
| `GET /api/session` without credentials | `401` JSON `{"_tag":"UnauthorizedError"}` — authentication works, not the cause |
| `GET /api/info`, `/api/project` with credentials | `200 text/html` (the web shell), also with `Accept: application/json`, a trailing slash, `?x=1`, or `/api/v2/info` |
| `GET /api/health` | `200 application/json` `{"healthy":true}` |
| `GET /project` | `200 application/json`, but a different shape (`worktree`, no `canonical`) |
| Proxy | none configured; the server bound directly to `127.0.0.1` |

Cause: **server build / route set**, not authentication, endpoint prefix (the `/api` prefix does serve
session and event), proxy routing or transport. Unknown `/api/*` paths in that build fall through to the
web UI, which is why an HTML 200 looked like data. Mapping `/api/project` to `/project` would still not
decode the audited shape, so the client does not remap anything.

A connection attempt that lands on that build now fails `health` as `.incompatibleAPI(feature: "server
info")`; Phase 5 must present that as “this address is not an OpenCode V2 server”, separately from a
rejected password (`.status(401)`) and an unreachable host (`.transport`).

## Not verified

- **`/api/info` and `/api/project` against a real V2 server**: no build with those audited routes was
  available. They remain covered by fixture tests of the audited shapes, and the live probe recorded the
  incompatibility rather than treating it as success.
- **iPhone/iPad visual comparison**: the original app is unavailable; October screenshots are evidence, not
  a target.
- **`/api/info` `pid` numeric type** across older servers: decoded as `Int`, as the audited payload does.
- **Haptic feel on other devices**: one iPhone Air observation; the vocabulary is unchanged.
- **Local-network denial classification**: `URLError -1009` is what this iOS version reports; a different
  version may classify a denial differently, and the client maps it to the shared unreachable copy.

## Next

1. P5 (`ios-shell`): wire `OpenCodeClient` into the launch states, pairing redemption and the reconnect
   loop, and add the network-path observation `RetryEnvironment` currently stubs.
2. P6/P7 add the remaining route call sites; their models already exist where the event stream needs them.
3. P8 adds the transcript consumer and, with it, the off-screen event pressure policy (D-23).
