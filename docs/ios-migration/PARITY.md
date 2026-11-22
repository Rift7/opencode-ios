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
- New code: `ios` branch from the same `dev` SHA. P5 merged as `3b34932c` (PR #4); P6 branched from
  that head as `ios-home`.

## App shell

| Behaviour | Android source (`dev`) | Recovered iOS source | New path | Status |
| --- | --- | --- | --- | --- |
| Process entry, root store, scene phase | `app/src/main/kotlin/ai/opencode/app/OpenCodeApplication.kt`, `MainActivity.kt` | `OpenCode/App/OpenCodeApp.swift` | `ios/OpenCode/App/OpenCodeApp.swift` | done — one store, `.task`, `scenePhase` forwarding, `.onOpenURL` |
| Launch restore: saved server, list and cache | `app/AppFeature.kt` (`State.initial`), `server/ServerSharedKeys.kt` | `AppFeature.swift` | `OpenCodeKit/Sources/OpenCodeApp/AppFeature.swift`, `OpenCodeServer/Address/ServerSharedKeys.swift` | done — missing/corrupt/unavailable are distinct; a Keychain failure never deletes or overwrites credentials |
| Saved-data trust and explicit replacement | `app/AppFeature.kt` (`knownServers`, `remember`), `server/ServerSharedKeys.kt` | `AppFeature.swift` | same (`SavedDataState`, `SavedDataWarningBanner`) | done — unreadable data blocks automatic writes; a manual connection is shown but not persisted until Retry succeeds or the person confirms Replace |
| Manual entry from storage or corrupt data | `app/AppView.kt` | `AppView.swift` | `ios/OpenCode/App/RootView.swift` | done — Enter Manually works from both failure screens; the resulting connection keeps a storage warning |
| Attempt and stream identity | `app/AppFeature.kt` (`connectionGeneration`), `drawer/HomeConnectionFeature.kt` | not recoverable — native | `OpenCodeKit/Sources/OpenCodeApp/AppFeature.swift` (`ConnectionFeature.Token`) | done — try, replace, background, path loss and disconnect invalidate both identities; delayed callbacks are tested |
| Central connection eligibility | `server/retry/NetworkPath.kt`, `app/AppFeature.kt` | `NetworkPath.swift` | same (`canAttempt`) | done — work starts only in the foreground with a non-offline path; an offline restore recovers on path return without a manual retry |
| Launch states (disconnected, connecting, loading, connected, reconnecting, failed) | `app/AppFeature.kt` (`Connection` enum) | `AppFeature.swift`, `AppView.swift` | `ios/OpenCodeKit/Sources/OpenCodeApp/AppFeature.swift`, `ios/OpenCode/App/RootView.swift` | done — typed phases and actionable failures |
| Connection state machine and identity guard | `app/AppFeature.kt` (`connectionGeneration`, `ConnectionAttempt`) | `AppFeature.swift` | `OpenCodeKit/Sources/OpenCodeApp/AppFeature.swift` (`ConnectionFeature`) | done — identified child state, attempt/stream tokens seeded per connection, stale callbacks ignored |
| Address race and authoritative REST refresh | `server/ServerLink.kt`, `drawer/HomeConnectionFeature.kt` | `OpenCodeClient+Connection.swift` | `OpenCodeServer/Address/ServerLink.swift`, `OpenCodeServer/Client/OpenCodeClient.swift` | done — preferred head start, 401 preference; projects refresh on every handshake and overflow |
| Network path observation | `server/retry/NetworkPath.kt` | `NetworkPath.swift` | `OpenCodeCore/Network/NetworkPathClient.swift`, `OpenCodeServer/Retry/NetworkPathRetry.swift` | done for the seam and state transitions; the live `NWPathMonitor` path is simulator/device-only |
| Pairing link, saved servers | `app/AppFeaturePairing.kt`, `AppFeatureServers.kt` | `AppFeature+Pairing.swift`, `+Servers.swift` | same; Home switcher in `ios/OpenCode/Drawer/HomeView.swift` | done for paste, deep links and the connected server switcher; disconnect exists, forget/edit and custom headers are P11 |
| Manual server form, validation | `app/AppView.kt` | `AppView.swift` | `ios/OpenCode/App/RootView.swift` | partial — name/address/username/password, typed validation, reachable from storage and corrupt screens; custom headers and error-report copy deferred |
| Pairing confirmation | `app/AppFeaturePairing.kt` (`PendingPairing`) | `AppFeature+Pairing.swift` | `OpenCodeKit/Sources/OpenCodeApp/AppFeature.swift` | done — an opened link is parsed without network and needs Pair |
| QR scanning | `feature/settings/.../servers/PairingScanner.kt` | `Settings/PairingScanner.swift` | — | deferred to a later phase; device-only, no scanner in P5 |


## Core

| Behaviour | Android source | Recovered iOS source | New path | Status |
| --- | --- | --- | --- | --- |
| Reducer/store semantics | `core/.../store/{Reducer,Effect,Store,TestStore}.kt` | TCA | `ComposableArchitecture` 1.26.2 (exact) | done — sibling order, effect order, cancellation identity, child-first `ifLet`, presentation dismissal and path-indexed cancellation tested on representative compositions (`OpenCodeAppTests/StoreSemanticsTests.swift`) |
| Dependency clients | `core/.../dependencies/DependencyValues.kt` | `Core/Dependencies` | `ios/OpenCodeKit/Sources/OpenCodeCore/{Dependencies,Transport,Haptics,Storage,Network}` (date, id, pasteboard, shared store, network path, haptics, HTTP transport) | done — every test value inert, guarded by `DependencyIsolationTests` |
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
| Client boundary | `server/OpenCodeClient.kt` | `OpenCodeClient.swift` | `OpenCodeServer/Client/OpenCodeClient.swift` | done for the shell and Home: health, pairing redeem, projects, session page (first/search/after), get session, active IDs, attention IDs, view receipt, delete, events with awaited phase callbacks; remaining call sites belong to their feature phases |
| Alternate-origin routing | `server/ServerLink.kt` | `OpenCodeClient+Family.swift` | `OpenCodeServer/Address/ServerLink.swift` | done — every candidate probed once, preferred head start, first answer wins, 401 preferred on failure |
| Network path | `server/retry/NetworkPath.kt` | `NetworkPath.swift` | `OpenCodeCore/Network/NetworkPathClient.swift` | done for observation, offline/wait and reroute-driven reconnect; live monitor hardware path unverified |
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
| Home, drawer, projects, Catch Up | `feature/drawer/.../{HomeFeature,HomeFeatureDrawerState,HomeFeatureSessionPages,HomeFeatureSessions}.kt`, `catchup/CatchUpFeature.kt` | `HomeFeature.swift`, `HomeView.swift`, `CatchUpStack.swift` | `OpenCodeKit/Sources/OpenCodeDrawer`, `ios/OpenCode/Drawer/HomeView.swift` | **done for P6 scope** — see the Home section below |
| Session, subagents, background work | `feature/session/.../SessionFeature.kt` | `SessionFeature.swift`, `SessionView.swift` | `.../OpenCodeSession` | not started (P6 only carries a `SessionSelection` to a placeholder) |
| Transcript | `feature/transcript/.../TranscriptEntry.kt`, `list/` | `TranscriptEntry.swift`, `TranscriptListViewController.swift` | `.../OpenCodeTranscript` | not started |
| Composer, pending inputs | `feature/composer/.../ComposerTextInput.kt`, `RequestDockFeature.kt` | `ComposerTextInput.swift`, `RequestReviewView.swift` | `.../OpenCodeComposer` | not started |
| Media, agent files, browser | `feature/media/.../` | `Media/`, `Browser/` | `.../OpenCodeMedia` | not started |
| Settings, experiments, diagnostics | `feature/settings/.../SettingsFeature.kt` | `SettingsView.swift`, `DiagnosticsView.swift` | `.../OpenCodeSettings` | not started |
| Notifications, share, Live Activities | `feature/system/.../` | `System/`, `OpenCodeShare/`, `OpenCodeWidgets/` | `.../OpenCodeSystem` | not started |
| Voice, dictation | `feature/voice/.../VoiceFeature.kt` | `Voice/` | `.../OpenCodeVoice` | not started |

## Home (P6)

| Behaviour | Android source (`dev = 7358160e`) | Recovered iOS evidence | New path | Status |
| --- | --- | --- | --- | --- |
| Authoritative Home snapshot: projects, first root page, active IDs, next cursor | `drawer/HomeFeatureConnection.kt` (`refreshSnapshot`, last changed at baseline), `server/live/LiveFamily.kt` (`requestHomeSnapshot`) | `HomeFeature.swift` (description only) | `HomeFeature.refreshed`, `HomeSnapshotStore`, `OpenCodeClient.sessionPage(.first)` + `.activeSessionIDs` | done — 250 ms debounce, cancel-in-flight, generation/request guards; REST remains authoritative after reconnect and overflow |
| Bounded, versioned persistence per server | `server/ServerSharedKeys.kt` (`cachedHomeSnapshots`, `home-snapshots.json`) | `HomeFeature.swift` (description only) | `HomeSnapshot` v1, 8 servers × 50 sessions, actor in `HomeModels.swift` | done — atomic write, decode/version failures reported; legacy `cachedServerSummaries` removed after a successful write |
| Drawer: search, pins, read/unread, status dots, project labels | `feature/drawer/list/DrawerListModel.kt`, `HomeFeatureDrawerState.kt` (`visibleSessions`, `drawerSessions`, `StatusSnapshot`) | `HomeView.swift` (description only) | `HomeFeature` derived state; `HomeView` drawer | done — root/unarchived/hidden rules, pin order, attention > running > unread, local + server search |
| Paging (50 per page) and retry | `HomeFeatureSessionPages.kt` (`sessionPageSize = 50`, `OlderSessions`, `SessionSearch`) | not recoverable | `HomeFeature.loadMore` / `.olderLoaded` / `.searchLoaded` | done — footer spinner/retry for a failed first search, search append and ordinary page; each retry keeps its cursor/query, stale results ignored |
| Server-scoped local records | `core/.../sharing/SharedKeys.kt` (`followed-sessions`, `session-read-dates`, `manually-unread-sessions`, `muted-sessions`, `hidden-sessions`, `last-viewed-sessions`) | `SharedKeys.swift` | `HomeSharedKeys`, `HomeFeature.key(_:)` | done — `serverPersistenceID|sessionID`, tested across two servers |
| Catch Up filtering and stack | `catchup/CatchUpFeature.kt`, `HomeFeatureDrawerState.kt` (`catchUpSessions`, `needsCatchUp`), tests `catchup/CatchUpTests.kt` | `CatchUpStack.swift` (description only) | `HomeFeature` (`catchUpSessions`, `catchUpCardDismissed`, `catchUpUndoTapped`, `catchUpFinished`) | done for P6 — attention-first, running excluded, muted/archived/subagent excluded; last card closes to the drawer's All Caught Up row |
| Mark read / keep unread / undo / failure | same, `requestViewSession` | `HomeFeature.swift` (description only) | `HomeFeature.markRead`, `readReceiptFinished`, `CatchUpView` | done — optimistic local read, `POST /view`, receipt acknowledges only its own watermark so newer activity stays unread, restore on failure, Undo cancels the receipt and restores the card; delayed view events below a Mark Unread or undone watermark are ignored |
| Delete with backup and reconciliation | `HomeFeatureDrawer.kt` (`hideSession`, `restoreSession`, `DeleteSessionResponse`) | not recoverable | `HomeFeature.confirmDeletion`, `restoreDeletion`, `reconcileDeletions`, `purgeLocalRecords` | done — row leaves at once, DELETE in flight, failure reinserts at its index with active/attention state and a notice; success purges this phone's records and leaves a tombstone so a pre-delete refresh cannot resurrect it; disconnect/reconnect reconciles in-flight deletes from REST. Two-phase server deletion is P7 |
| What's New row, routing and seen state | `feature/settings/whatsnew/WhatsNewFeature.kt`, `WhatsNewView.kt`, `HomeFeature.kt` (`showsWhatsNewButton`) | `WhatsNew*` (description only) | `HomeFeature.whatsNew`, `WhatsNewCatalog`, `WhatsNewView` | done for P6 mechanism — unseen dot, page, seen-on-close, persisted `whats-new-seen`; the shipped release catalogue and Try It destinations are P11 |
| Saved-server switch | `app/AppFeatureServers.kt`, `switcher/ServerSwitcher.kt` | `AppFeature+Servers.swift` | `HomeView.ServerSwitcherView`, `AppFeature.connect(to:)` | done — switch replaces the connection and clears the old Home; disconnect available; forget/edit P11 |
| Live status and reconnect | `drawer/HomeConnectionFeature.kt` (connection status, reconnect refresh) | `HomeFeature.swift` (description only) | `AppFeature.homeIsLive`, `ConnectionFeature.Delegate.available/unavailable`, `HomeFeature.connectionResynchronized` | done — Home is live only in front, online and connected; interruption marks it unavailable; one authoritative refresh resumes after a handshake/overflow and replaces an earlier read |
| Attention event for a cold root/subagent | `HomeFeatureServerEvents.kt`, `live/LiveRequests.kt` (`requestHomeAttention`, ancestor walk) | `HomeFeature.swift` (description only) | `HomeFeature.resolveAttentionEvent`, `attentionEventResolved` | done — at most eight ancestry hops and one location read; root indicator updates without scanning every project; hint directories bounded to eight |
| App → Home → Session boundary | `HomeFeature.kt` (`openViewedSession`), `SessionPageStack.kt` | `SessionFeature`/`HomeFeature` (description only) | `SessionSelection` in `HomeModels.swift`; `AppFeature.sessionDestination`; `SessionPlaceholderView` | done for the boundary — stable server ID + session ID + explicit intent; P7 supplies the real destination |
| Motion | Compose springs and card flights (`CatchUpStackController.kt`) | UIKit card flights (unrecoverable) | platform sheet/navigation, press highlights, one drag threshold | native adaptation — no card flight or custom animation added; Reduce Motion inherits the platform |

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
| Local-network denial | Android 17 permission preflight with a dedicated denial message | iOS does not expose a preflight; the shell shows a generic unreachable message plus a Local Network settings hint, never a denial claim (D-35) |
| Storage identity | Android application id + keys | Keychain service derived at runtime from the configured bundle identifier; no historical identifier copied (D-32) |
| Connected destination | Home drawer and session list | P6 shows Home, the drawer and a session placeholder; P7 owns the session screen (D-36 superseded by D-43) |

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
| App reducer | `OpenCodeAppTests/AppFeatureTests.swift`, `ConnectionFeatureTests.swift`, `LaunchConfigurationTests.swift` | done |
| Home reducer and persistence | `OpenCodeDrawerTests/HomeFeatureTests.swift` | done — 18 tests covering pins, unread, server isolation, visibility, search/paging, stale responses, deletion recovery, Catch Up, What's New, snapshot bounds/versioning/migration and read-receipt failure |
| Server: address and cleartext policy | `OpenCodeServerTests/ServerAddressTests.swift` | done |
| Server: address race | `.../ServerLinkTests.swift` | done |
| Server: redirect rule | `.../RedirectRuleTests.swift` | done |
| Server: transport send/stream | `.../TransportTests.swift` | done |
| Server: pairing | `.../PairingLinkTests.swift` | done |
| Server: retry policy and loop | `.../RetryTests.swift` | done |
| Server: SSE parsing | `.../SSEParserTests.swift` | done |
| Server: event decoding | `.../ServerEventDecoderTests.swift` | done |
| Server: event batching | `.../EventBatcherTests.swift` | done |
| Server: event stream and reconnect | `.../EventStreamTests.swift`, `.../EventStreamPhaseTests.swift` | done |
| Server: loopback delegates and socket lifetime | `.../LocalFixtureServerTests.swift` | done (loopback only, opt-out env var); includes a compatible fixture connection |
| Server: live read-only smoke | `.../LiveServerTests.swift` | run once manually; skipped by default |
| Server: client requests | `.../OpenCodeClientTests.swift` | done |
| Bounded channel | `OpenCodeCoreTests/BoundedChannelTests.swift` | done; one pre-existing timing-sensitive expectation flaked once and passed on rerun |
| UI (XCUITest) | `OpenCodeUITests/{LaunchSmokeTests,ConnectionLifecycleUITests,KeychainProbeTests,SavedServerProbeTests,HomeUITests,HomeScreenshotUITests,HomeScrollTraceUITests}.swift` | done — 26 tests; P6 adds drawer search/select, server switching, Catch Up mark/keep/undo/finish, What's New seen state, Dynamic Type, accessibility label/keyboard dismissal, screenshots and a measured scroll trace |
