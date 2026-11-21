# iOS migration — status

## Baseline

| Item | Value |
| --- | --- |
| Integration branch | `ios` |
| Base commit | `7358160e808fb1870eeb20f5da8df832667019d1` (`origin/dev`) |
| Verified against | audit of 2026-11-21 (`docs/ios-migration/audit/AUDIT.md`) |
| `ios` head when P4 started | `d0fdf2f5cc3c37b0e0fab6146a49469f0ff86540` (PR #2, core foundation) |
| P4 branch | `ios-networking`, created from that `ios` head |
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
| 4 | Server: transport, retry, models, SSE, pairing | **complete on `ios-networking`** — draft PR open, not merged |
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
| Injectable monotonic clock | `OpenCodeKit/Sources/OpenCodeCore/Dependencies/ClockClient.swift` | `OpenCodeCoreTests/DependencyIsolationTests.swift` (every key has a test value), retry tests |
| Bounded pull channel | `OpenCodeKit/Sources/OpenCodeCore/Concurrency/BoundedChannel.swift` | `OpenCodeCoreTests/BoundedChannelTests.swift` |
| Request/response/stream seam, redirect rule | `OpenCodeKit/Sources/OpenCodeCore/Transport/{HTTPTransport,URLSessionTransport}.swift` | `OpenCodeServerTests/{TransportTests,RedirectRuleTests}.swift` |
| Server origin, saved server, endpoint encoding | `OpenCodeKit/Sources/OpenCodeServer/Address/{ServerOrigin,OpenCodeServer}.swift` | `ServerAddressTests` |
| Pairing parse and candidates | `OpenCodeKit/Sources/OpenCodeServer/Pairing/PairingLink.swift` | `OpenCodeServerTests/PairingLinkTests.swift` |
| Wire models | `OpenCodeKit/Sources/OpenCodeServer/Models/{JSONValue,ServerProject,OpenCodeSession,ServerShell,PromptBody}.swift` | client and event-suite decode tests |
| Central retry policy | `OpenCodeKit/Sources/OpenCodeServer/Retry/{RetryPolicy,NetworkRetry}.swift` | `RetryTests.swift` |
| Typed errors and copy | `OpenCodeKit/Sources/OpenCodeServer/Client/{OpenCodeClientError,ServerCopy}.swift` | client tests assert status, copy, log summary |
| SSE parsing and batching | `OpenCodeKit/Sources/OpenCodeServer/Events/{SSEParser,EventBatcher,ServerEvent,ServerEventDecoder,EventStream}.swift` | `SSEParserTests`, `ServerEventDecoderTests`, `EventBatcherTests`, `EventStreamTests` |
| Client dependency | `OpenCodeKit/Sources/OpenCodeServer/Client/OpenCodeClient.swift` | `OpenCodeClientTests` |
| ATS and local-network declaration | `ios/OpenCode/Info.plist`, `ios/project.yml` | build; simulator cannot exercise the prompt |
| Fixtures | `OpenCodeKit/Sources/OpenCodeTestSupport/NetworkGuard.swift` (chunks, redirects, recorded requests) | transport tests |

Adopted values and their freshness (all against `dev = 7358160e`):

| New behaviour | Android source | File last changed | Treatment |
| --- | --- | --- | --- |
| Cleartext policy (RFC 1918, CGNAT, link-local, ULA, `.local`, overlay names) | `server/.../TransportSecurity.kt` | `f79a895e`, 2026-11-14 | values adopted; ATS is the native equivalent of the manifest declaration |
| Retry presets, equal jitter, classification, `Retry-After` | `server/.../retry/NetworkRetry.kt` | `f79a895e`, 2026-11-14 | policies adopted; clock and task structure native (D-21) |
| Pairing forms, validation, loopback filtering, copy | `server/.../OpenCodePairingLink.kt`, `live/LiveConnection.kt` | `5e4b4219`, 2026-11-16 | adopted, including current copy |
| Session page query, filters, envelopes | `server/.../live/LiveSessions.kt` | `8566441f`, 2026-11-17 | adopted |
| Event set, decode rules, batching | `server/.../live/LiveEvents.kt`, `EventBatcher.kt` | `4c1e0054`, 2026-11-20 (events); `f79a895e` (batcher) | adopted; transcript pressure shedding deferred (D-23) |
| `location[directory]` encoding | `server/.../internal/Urls.kt` | `5fa3aab0`, 2026-10-24 | adopted, byte-for-byte expectations in tests |
| Models and optionality | `server/.../model/Models.kt`, `live/Payloads.kt` | `4c1e0054` (Models), same date | adopted for the modelled subset; the rest listed in `PROTOCOL_COVERAGE.md` |

No recovered iOS source file exists for these areas; every value above carries current `dev` behaviour and
is labelled a native decision, not a port.

## Verified in this phase

| Command | Result |
| --- | --- |
| `swift test --package-path OpenCodeKit` | 205 tests pass: 125 server, 66 core, 14 app |
| `ios/scripts/verify.sh` | toolchain 27.2 / Swift 6.4.2 / SDK 27.2; app build succeeds; `OpenCodeTests` Swift Testing suite passes (2 tests); 4 UI tests pass; package suites pass |
| `plutil -p …/OpenCode.app/Info.plist` | `NSAllowsLocalNetworking`, the overlay exception domains and `NSLocalNetworkUsageDescription` are in the built app |

Targeted checks behind those totals: request construction and header application, 401/404 copy,
retry-safety matrix, cancellation, fragmented SSE frames (byte-at-a-time and chunked), 16 MiB frame bound,
unknown-event tolerance, overflow → `EventStreamOverflow`, reconnect after a dropped connection, one-401
stop, malformed pairing rejection with reasons, redemption sending one unauthenticated GET per candidate
with redirects refused, and credential isolation through the redirect rule.

## Not verified

- **Device-only paths**: haptics, the local-network permission prompt, and any ATS behaviour for a cleartext
  LAN server. The simulator build proves the plist keys ship; it does not prove the prompt or the LAN load.
- **Live server**: no live smoke was run. The opt-in live check in `docs/parity/server.md` is not enabled in
  this environment, and no server address or credential was configured.
- **Redirect integration through URLSession**: the decision is unit-tested; the `URLProtocol` fixture cannot
  synthesize a redirect that reaches the session delegate (D-22). The wiring compiles and is six lines; it is
  not claimed as proven.
- **`/api/info` `pid` numeric type** across older servers: decoded as `Int`, as the audited payload does; the
  audit records the uncertainty.
- **Visual comparison**: the original app is unavailable; October screenshots are evidence, not a target.

## Next

1. P5 (`ios-shell`): wire `OpenCodeClient` into the launch states, pairing redemption and the reconnect loop;
   add the live network-path observation the retry environment currently stubs.
2. P6/P7 add the remaining route call sites; their models already exist where the event stream needs them.
3. P8 adds the transcript consumer and, with it, the off-screen event pressure policy (D-23).
