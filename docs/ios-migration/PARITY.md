# iOS migration — parity map

Status vocabulary: `not started`, `scaffold`, `partial`, `done`. A row is `done` only when the behaviour exists,
is tested, and the test passes. Every claim names a source path; commit SHAs distinguish current `dev` behaviour
from historical iOS evidence.

Scaffold scope: the app boots into an explicit disconnected, loading or failed state; no server is contacted and
no session screen exists yet.

`done` means the behaviour exists **and** a test in this repository demonstrates it. Linking a library is not
a demonstrated behaviour: `ComposableArchitecture` is linked, and the ordering, cancellation-identity and
presentation semantics the Kotlin store relies on are now demonstrated by tests over representative
compositions. Phase mapping and the remaining work list are in `PHASES.md`.

Baselines:

- Behaviour: `dev = 7358160e808fb1870eeb20f5da8df832667019d1`.
- iOS evidence: parity corpus synced at iOS `01eef583`; screenshots at `d809b1e` and `16b40f7` (October).
- New code: `ios` branch from the same `dev` SHA (`ios` head `d0fdf2f5` when Phase 4 branched; Phase 4
  work is on `ios-networking`).

## App shell

| Behaviour | Android source (`dev`) | Recovered iOS source | New path | Status |
| --- | --- | --- | --- | --- |
| Process entry, root store, scene phase | `app/src/main/kotlin/ai/opencode/app/OpenCodeApplication.kt`, `MainActivity.kt` | `OpenCode/App/OpenCodeApp.swift` | `ios/OpenCode/App/OpenCodeApp.swift` | scaffold |
| Launch states (disconnected, loading, failed) | `app/AppFeature.kt` (`Connection` enum) | `AppFeature.swift`, `AppView.swift` | `ios/OpenCodeKit/Sources/OpenCodeApp/AppFeature.swift`, `ios/OpenCode/App/RootView.swift` | scaffold |
| Connection state machine | `app/AppFeature.kt` | `OpenCode/App/AppFeature.swift` | `ios/OpenCodeKit/Sources/OpenCodeApp` | scaffold (probe inert) |
| Pairing link, saved servers | `app/AppFeaturePairing.kt`, `AppFeatureServers.kt` | `AppFeature+Pairing.swift`, `+Servers.swift` | same | not started |
| Manual server form, failure report | `app/AppView.kt` | `AppView.swift` | same | not started |
| QR scanning | `feature/settings/.../servers/PairingScanner.kt` | `Settings/PairingScanner.swift` | same | not started |

## Core

| Behaviour | Android source | Recovered iOS source | New path | Status |
| --- | --- | --- | --- | --- |
| Reducer/store semantics | `core/.../store/{Reducer,Effect,Store,TestStore}.kt` | TCA | `ComposableArchitecture` 1.26.2 (exact) | done — sibling order, effect order, cancellation identity, child-first `ifLet`, presentation dismissal and path-indexed cancellation tested on representative compositions (`OpenCodeAppTests/StoreSemanticsTests.swift`) |
| Dependency clients | `core/.../dependencies/DependencyValues.kt` | `Core/Dependencies` | `ios/OpenCodeKit/Sources/OpenCodeCore/{Dependencies,Transport,Haptics}` (probe, date, id, haptics, HTTP transport) | done — five keys, every test value inert, guarded by `DependencyIsolationTests` |
| Shared keys and storage | `core/.../sharing/{Shared,SharedKeys}.kt` | `Core/SharedKeys.swift`, `Keychain.swift` | `.../Storage/{KeyValueStorage,SharedKeys}.swift` | done — four foundation keys, defaults, storage routing, round-trip and failure propagation tested |
| Keychain | `core/.../sharing/LiveSharedBytes.kt` | `Core/Keychain.swift` | `.../Storage/{KeyValueStorage,KeychainStorage}.swift` | done — typed `value`/`missing`/`failure` outcomes, failure mapping unit-tested, round-trip verified in the app process |
| Semantic colour tokens | `core/.../ui/{BrandPalette,OpenCodeColors}.kt` | `Core/Theme/Theme.swift` (system colours) | `.../Design/OpenCodeColorTokens.swift` | done |
| Type tokens | `core/.../ui/OpenCodeTypography.kt` | system text styles | `.../Design/OpenCodeTypeTokens.swift` | done |
| Spacing and radius tokens | `core/.../ui/OpenCodeShapes.kt` (`OpenCodeSpacing`, `OpenCodeRadius`, `OpenCodeShapeGeometry`) | not recoverable — native decision (D-17) | `.../Design/OpenCodeLayoutTokens.swift` | done — grid, radius scale and corner clamp tested |
| Motion vocabulary | `core/.../motion/{MotionRole,MotionConstants,MotionReduce}.kt` | not recoverable — native decision (D-18) | `.../Motion/OpenCodeMotion.swift` | done — fourteen roles, per-phase curves, Reduce Motion collapse, pose and stagger tested; no screen animates yet |
| Logging | `core/.../log/AppLog.kt` | `Core/AppLog.swift` | `.../Logging/AppLog.swift` | scaffold — structured public fields only (numbers/booleans), free text private; not the full Android journal |
| Test isolation and network guard | (test-only `TestNetworkBlock`) | `TestIsolationGuard` | `.../OpenCodeTestSupport` | done — isolated storage, network guard, and a transport seam whose test value blocks |
| Preview states | n/a | SwiftUI previews | `ios/OpenCode/App/RootView.swift` (`#Preview` × 2) | scaffold |
| Haptics vocabulary | `core/.../haptics/HapticsClient.kt` | not recoverable — native decision (D-19) | `.../Haptics/HapticsClient.swift` | done for the seam and vocabulary; physical-device feel unverified |

## Server

| Behaviour | Android source | Recovered iOS source | New path | Status |
| --- | --- | --- | --- | --- |
| Host classification and cleartext policy | `server/TransportSecurity.kt` | not recoverable — native decision (D-22) | `OpenCodeCore/Network/HostAddress.swift` | done — private/overlay/local classification and refusal tested; ATS keys in `ios/OpenCode/Info.plist` |
| Transport and response streaming | `server/OpenCodeTransport.kt`, `live/LiveTransport.kt` | `OpenCodeClient+Transport.swift` | `OpenCodeCore/Transport/{HTTPTransport,URLSessionTransport}.swift` | done for send and stream — ephemeral, no cookies/cache, bounded chunks; one request session and one per stream (D-26); redirect rule and real redirect delegates tested (D-22, D-28) |
| Credential scope | `OpenCodeServer.kt`, `live/LiveTransport.kt` | not recoverable | `HTTPRedirectRule`, `OpenCodeServer.wireHeaders` | done — Basic header applied by origin, cross-origin hop refused and rule-tested |
| Retry, backoff, `Retry-After`, idempotency | `server/retry/NetworkRetry.kt` | `NetworkRetry.swift` | `OpenCodeServer/Retry/{RetryPolicy,NetworkRetry}.swift` | done — presets, classification, equal jitter, window, cancellation, unsafe-write rule tested |
| Wire models | `server/model/*.kt`, `live/Payloads.kt` | `OpenCodeClient+Payloads.swift` | `OpenCodeServer/Models/*.swift` | partial — session, project, shell, job, prompt body, model ref and envelopes modelled; remaining routes listed in `PROTOCOL_COVERAGE.md` |
| Client boundary | `server/OpenCodeClient.kt` | `OpenCodeClient.swift` | `OpenCodeServer/Client/OpenCodeClient.swift` | partial — health, pairing redeem, projects, session page, get session, active IDs, events; other call sites belong to their feature phases |
| SSE decode and batching | `server/live/LiveEvents.kt`, `EventBatcher.kt` | `OpenCodeClient+Events.swift` | `OpenCodeServer/Events/*.swift` | done for framing, decoding, coalescing, ordering and bounds; transcript pressure shedding deferred (D-23) |
| Reconnect and watchdog | `server/live/LiveEvents.kt`, `retry/NetworkRetry.kt` | not recoverable | `EventStreamRunner`, `EventStream` | done — reconnect schedule, 401 stop, 45 s idle watchdog, connect deadline covering headers, bounded overflow recovery with a REST resync callback tested (D-27) |
| Pairing decode and redeem | `server/OpenCodePairingLink.kt`, `live/LiveConnection.kt` | `OpenCodePairingLink.swift` | `OpenCodeServer/Pairing/PairingLink.swift`, `OpenCodeClient.redeemPairing` | done — every form, validation reasons, loopback filtering, non-fetching draw link, one unauthenticated GET per candidate tested |
| Error copy and log safety | `server/OpenCodeClientError.kt` | `OpenCodeClientError.swift` | `OpenCodeServer/Client/{OpenCodeClientError,ServerCopy}.swift` | done — typed facts, copy at the edge, status/transport-only log summary; a web page is `.incompatibleAPI`, distinct from 401 and transport (D-31) |
| Family BFS | `server/live/LiveFamily.kt` | `OpenCodeClient+Family.swift` | — | not started (P6/P7) |

## Feature areas

Each area follows the same shape: reducer → dependency clients → persistence → wire routes/events →
cancellation identities → error states. The full extraction is in `docs/ios-migration/audit/FEATURE_MAP.md`.

| Area | Android entry point | Recovered iOS source | New path | Status |
| --- | --- | --- | --- | --- |
| Home, drawer, projects, Catch Up | `feature/drawer/.../HomeFeature.kt` | `HomeFeature.swift`, `HomeView.swift`, `CatchUpStack.swift` | `ios/OpenCodeKit/Sources/OpenCodeDrawer` | not started |
| Session, subagents, background work | `feature/session/.../SessionFeature.kt` | `SessionFeature.swift`, `SessionView.swift` | `.../OpenCodeSession` | not started |
| Transcript | `feature/transcript/.../TranscriptEntry.kt`, `list/` | `TranscriptEntry.swift`, `TranscriptListViewController.swift` | `.../OpenCodeTranscript` | not started |
| Composer, pending inputs | `feature/composer/.../ComposerTextInput.kt`, `RequestDockFeature.kt` | `ComposerTextInput.swift`, `RequestReviewView.swift` | `.../OpenCodeComposer` | not started |
| Media, agent files, browser | `feature/media/.../` | `Media/`, `Browser/` | `.../OpenCodeMedia` | not started |
| Settings, experiments, diagnostics | `feature/settings/.../SettingsFeature.kt` | `SettingsView.swift`, `DiagnosticsView.swift` | `.../OpenCodeSettings` | not started |
| Notifications, share, Live Activities | `feature/system/.../` | `System/`, `OpenCodeShare/`, `OpenCodeWidgets/` | `.../OpenCodeSystem` | not started |
| Voice, dictation | `feature/voice/.../VoiceFeature.kt` | `Voice/` | `.../OpenCodeVoice` | not started |

## Deliberate divergences

Recorded here so they are not mistaken for missing work.

| Item | Android behaviour | New iOS decision |
| --- | --- | --- |
| Typography | Inter + OpenMono, desktop scale | SF + SF Mono (D-1) |
| Motion curves | Compose springs from `(duration, bounce)` via `ω = 2π/duration` | Same role names and numbers; SwiftUI's perceptual `duration`/`bounce` (D-18) |
| Haptics | Composed vibrator primitives with a predefined fallback | UIKit feedback generators mapped from the same vocabulary (D-19) |
| Transcript motion | bottom-anchored `LazyColumn`, no follower | pending native decision (`P-2`) |
| Photo picking | system picker | system picker proposed; no in-app photo sheet |
| Autocomplete | list, next-frame filtering | SwiftUI-native list |
| Quotes | quote cards | pending product decision |
| Notifications | FCM, relay absent | Experimental, off until a relay exists |
| Redirect tests | OkHttp interceptor + MockWebServer | pure `HTTPRedirectRule` plus a loopback HTTP server that exercises the real URLSession delegate (D-22, D-28) |
| Cleartext | manifest cleartext plus an interceptor | ATS exceptions plus `TransportSecurity`, both narrower than "cleartext everywhere" (D-22) |
| Time in retries | `Clock` dependency over coroutines | `ClockClient` with recording/gated doubles (D-21) |

## Test coverage

| Area | Tests | Status |
| --- | --- | --- |
| Design tokens (type, colour) | `OpenCodeKit/Tests/OpenCodeCoreTests/DesignTokenTests.swift` | done |
| Layout tokens (spacing, radius) | `.../LayoutTokenTests.swift` | done |
| Motion vocabulary | `.../MotionTests.swift` | done |
| Haptics | `.../HapticsTests.swift` | done |
| Log privacy boundary | `.../LoggingTests.swift` | done |
| Shared keys and storage | `.../SharedStoreTests.swift`, `.../KeychainFailureTests.swift` | done |
| Dependency isolation and transport boundary | `.../DependencyIsolationTests.swift`, `.../TransportBoundaryTests.swift`, `.../NetworkAndIsolationTests.swift` | done |
| Store semantics | `OpenCodeAppTests/StoreSemanticsTests.swift` | done |
| App reducer | `OpenCodeAppTests/AppFeatureTests.swift`, `LaunchConfigurationTests.swift` | done |
| Server: address and cleartext policy | `OpenCodeServerTests/ServerAddressTests.swift` | done |
| Server: redirect rule | `.../RedirectRuleTests.swift` | done |
| Server: transport send/stream | `.../TransportTests.swift` | done |
| Server: pairing | `.../PairingLinkTests.swift` | done |
| Server: retry policy and loop | `.../RetryTests.swift` | done |
| Server: SSE parsing | `.../SSEParserTests.swift` | done |
| Server: event decoding | `.../ServerEventDecoderTests.swift` | done |
| Server: event batching | `.../EventBatcherTests.swift` | done |
| Server: event stream and reconnect | `.../EventStreamTests.swift` | done |
| Server: loopback delegates and socket lifetime | `.../LocalFixtureServerTests.swift` | done (loopback only, opt-out env var) |
| Server: live read-only smoke | `.../LiveServerTests.swift` | run once manually; skipped by default |
| Server: client requests | `.../OpenCodeClientTests.swift` | done |
| Bounded channel | `OpenCodeCoreTests/BoundedChannelTests.swift` | done |
| UI (XCUITest) | `OpenCodeUITests/{LaunchSmokeTests,KeychainProbeTests}.swift` | done for the launch states |
