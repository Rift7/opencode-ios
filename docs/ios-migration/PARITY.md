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
- New code: `ios` branch from the same `dev` SHA. P5 merged as `3b34932c` (PR #4); P6 as `7966dcfe`
  (PR #5); P7 as `92a7c677` (PR #6). P8 branched from `92a7c677` as `ios-transcript`.

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
| Wire models | `server/model/*.kt`, `live/Payloads.kt` | `OpenCodeClient+Payloads.swift` | `OpenCodeServer/Models/*.swift` | partial — session, project, shell, job, prompt body, model ref, permission/form request models, family, shell output, transcript items/tools/files/images/compaction/notices/errors and envelopes modelled; remaining routes listed in `PROTOCOL_COVERAGE.md` |
| Client boundary | `server/OpenCodeClient.kt` | `OpenCodeClient.swift` | `OpenCodeServer/Client/{OpenCodeClient,SessionOperations,TranscriptOperations}.swift` | done for the shell, Home, P7 and P8: health, pairing redeem, projects, session page (first/search/after), get session, active IDs, attention IDs, view receipt, delete, events with awaited phase callbacks, interrupt, family, pending requests/replies, inbox delivery, shells/output/stop, jobs/cancel, transcript window/history/message; remaining call sites belong to their feature phases |
| Alternate-origin routing | `server/ServerLink.kt` | `OpenCodeClient+Family.swift` | `OpenCodeServer/Address/ServerLink.swift` | done — every candidate probed once, preferred head start, first answer wins, 401 preferred on failure |
| Network path | `server/retry/NetworkPath.kt` | `NetworkPath.swift` | `OpenCodeCore/Network/NetworkPathClient.swift` | done for observation, offline/wait and reroute-driven reconnect; live monitor hardware path unverified |
| SSE decode and batching | `server/live/LiveEvents.kt`, `EventBatcher.kt` | `OpenCodeClient+Events.swift` | `OpenCodeServer/Events/*.swift` | done — framing, decoding, coalescing, ordering and bounds; P8 adopts the off-screen policy as batched coalescing plus on-demand Markdown parsing, never dropping deltas (D-61) |
| Reconnect and watchdog | `server/live/LiveEvents.kt`, `retry/NetworkRetry.kt` | not recoverable | `EventStreamRunner`, `EventStream` | done — reconnect schedule, 401 stop, 45 s idle watchdog, connect deadline covering headers, bounded overflow recovery with a REST resync callback tested (D-27) |
| Pairing decode and redeem | `server/OpenCodePairingLink.kt`, `live/LiveConnection.kt` | `OpenCodePairingLink.swift` | `OpenCodeServer/Pairing/PairingLink.swift`, `OpenCodeClient.redeemPairing` | done — every form, validation reasons, loopback filtering, non-fetching draw link, one unauthenticated GET per candidate tested |
| Error copy and log safety | `server/OpenCodeClientError.kt` | `OpenCodeClientError.swift` | `OpenCodeServer/Client/{OpenCodeClientError,ServerCopy}.swift` | done — typed facts, copy at the edge, status/transport-only log summary; a web page is `.incompatibleAPI`, distinct from 401 and transport (D-31) |
| Family BFS | `server/live/LiveFamily.kt` | `OpenCodeClient+Family.swift` | `OpenCodeServer/Client/SessionOperations.swift` (`sessionFamily`) | done — six child pages in flight, 100-session cap, visited set, queue-order commit and bounded running ancestry (24 lookups); tested with a cycle and a cap |

## Feature areas

Each area follows the same shape: reducer → dependency clients → persistence → wire routes/events →
cancellation identities → error states. The full extraction is in `docs/ios-migration/audit/FEATURE_MAP.md`.

| Area | Android entry point | Recovered iOS source | New path | Status |
| --- | --- | --- | --- | --- |
| Home, drawer, projects, Catch Up | `feature/drawer/.../{HomeFeature,HomeFeatureDrawerState,HomeFeatureSessionPages,HomeFeatureSessions}.kt`, `catchup/CatchUpFeature.kt` | `HomeFeature.swift`, `HomeView.swift`, `CatchUpStack.swift` | `OpenCodeKit/Sources/OpenCodeDrawer`, `ios/OpenCode/Drawer/HomeView.swift` | **done for P6 scope** — see the Home section below |
| Session, subagents, background work | `feature/session/.../SessionFeature.kt` | `SessionFeature.swift`, `SessionView.swift` | `.../OpenCodeSession`, `ios/OpenCode/Session/SessionView.swift` | **done for P7 scope** — see the Session section below; transcript and composer remain P8/P9 |
| Transcript | `feature/transcript/.../TranscriptEntry.kt`, `list/`, `markdown/` | `TranscriptEntry.swift`, `TranscriptListViewController.swift` (historical) | `.../OpenCodeTranscript`, `ios/OpenCode/Transcript` | **done for P8 scope** — see the Transcript section below |
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
| Delete with backup and reconciliation | `HomeFeatureDrawer.kt` (`hideSession`, `restoreSession`, `DeleteSessionResponse`) | not recoverable | `HomeFeature.confirmDeletion`, `restoreDeletion`, `verifyPendingDeletions`, `purgeLocalRecords` | done — row leaves at once, DELETE in flight, failure reinserts at its index with active/attention state and a notice; success purges this phone's records and leaves a tombstone so a pre-delete refresh cannot resurrect it. An unsettled delete is verified by a targeted `GET /api/session/{id}` after reconnect, not by the first page; inconclusive reads keep pins/read history, and a running delete is not failed merely because the session exists. Two-phase server deletion is P7 |
| What's New row, routing and seen state | `feature/settings/whatsnew/WhatsNewFeature.kt`, `WhatsNewView.kt`, `HomeFeature.kt` (`showsWhatsNewButton`) | `WhatsNew*` (description only) | `HomeFeature.whatsNew`, `WhatsNewCatalog`, `WhatsNewView` | done for P6 mechanism — unseen dot, page, seen-on-close, persisted `whats-new-seen`; the shipped release catalogue and Try It destinations are P11 |
| Saved-server switch | `app/AppFeatureServers.kt`, `switcher/ServerSwitcher.kt` | `AppFeature+Servers.swift` | `HomeView.ServerSwitcherView`, `AppFeature.connect(to:)` | done — switch replaces the connection and clears the old Home; disconnect available; forget/edit P11 |
| Live status and reconnect | `drawer/HomeConnectionFeature.kt` (connection status, reconnect refresh) | `HomeFeature.swift` (description only) | `AppFeature.homeIsLive`, `ConnectionFeature.Delegate.available/unavailable`, `HomeFeature.connectionResynchronized` | done — Home is live only in front, online and connected; interruption marks it unavailable; one authoritative refresh resumes after a handshake/overflow and replaces an earlier read |
| Attention event for a cold root/subagent | `HomeFeatureServerEvents.kt`, `live/LiveRequests.kt` (`requestHomeAttention`, ancestor walk) | `HomeFeature.swift` (description only) | `HomeFeature.resolveAttentionEvent`, `attentionEventResolved` | done — at most eight ancestry hops and one location read; root indicator updates without scanning every project; hint directories bounded to eight |
| App → Home → Session boundary | `HomeFeature.kt` (`openViewedSession`), `SessionPageStack.kt` | `SessionFeature`/`HomeFeature` (description only) | `SessionSelection` in `HomeModels.swift`; `AppFeature.sessionDestination` | done — stable server ID + session ID + explicit intent; P7 supplies the real destination |
| Motion | Compose springs and card flights (`CatchUpStackController.kt`) | UIKit card flights (unrecoverable) | platform sheet/navigation, press highlights, one drag threshold | native adaptation — no card flight or custom animation added; Reduce Motion inherits the platform |


## Session (P7)

| Behaviour | Android source (`dev = 7358160e`) | Recovered iOS evidence | New path | Status |
| --- | --- | --- | --- | --- |
| Session destination and App → Home → Session ownership | `HomeFeature.kt` (`openViewedSession`), `SessionPageStack.kt` | `SessionFeature`/`HomeFeature` (description only) | `AppFeature.session`, `SessionFeature.State(id:)`, `ios/OpenCode/Session/SessionView.swift` | done — a stable child identity, the selection's server is checked, a replacement creates a new child (cancelling the old effects), dismiss/switch/disconnect clear it |
| Ordinary selection vs Catch Up card read state | `HomeFeatureSessions.kt` (`sessionTapped`), `HomeFeatureCatchUp.kt` (`OpenTapped`) | `HomeFeature.swift` (description only) | Home's existing read path; `SessionSelection.intent` | done — a tapped row marks read; a Catch Up card opens with `.catchUpCard` and keeps the row unread. `HomeFeatureTests.catchUpCardKeepsUnread`, `AppFeatureTests.sessionOwnership` |
| Authoritative refresh reasons, IDs and coalescing | `SessionFeatureRefresh.kt` (`RefreshReason`), `SessionFeatureStream.kt` (`refreshRequested`, `refreshResponse`) | `SessionFeature.swift` (description only) | `RefreshReason`, `SessionRefresh`, `SessionFeature.requestRefresh` | done — eight reasons, one in-flight read, newest-wins request ID, follow-up for invalidation/settlement/runState; lifecycle duplicates coalesce; read not cancelled in flight. A selection with no cached session accepts its first snapshot; reconnect can start it |
| Snapshot/event race reconciliation | `SessionFeatureStream.kt` (raced events, 512 cap, replay) | not recoverable | `SessionFeature.receive`, `apply(raced:)`, `recordRaced`, `SessionRecovery` | done — events arriving during a read are replayed in order; execution, request, invalidation and durable-boundary races earn one follow-up. Crossing 512 batches discards the partial replay and stores a persistent recovery. A durable boundary keeps its 200 ms settlement delay; the requirement survives failed reads and clears only after a coherent authoritative transcript. `snapshotEventRace`, `invalidationRacingRead`, `overflowSettlementDelaysRecovery`, `failedRecoveryStaysRequired`, `repeatedOverflowDuringRecovery` |
| Durable settlement boundary and transcript read | `SessionFeatureRefresh.kt` (`acceptWindow`, 200 ms window, message/page scope) | `SessionFeature.swift` (description only) | `RefreshReason.settlement`, refresh effect, `applyTranscript` | done — every authoritative read includes the transcript; the 200 ms window, request identity, raced-event replay and follow-up are shared with P7. `settlementWindow`, `readPlan`, `eventRace` |
| Run lifecycle and Stop | `SessionFeatureRun.kt` (`interruptTapped`, `interrupt`, `settleStop`, `confirmRunState`) | `SessionFeature.swift` (description only) | `SessionRun`, `SessionFeature.interruptTapped`, `interruptEffect`, `settleStop` | done — generation guards, ambiguous-failure read, no blind second interrupt, 1/2/4/8 s settle, run-end check, typed failure |
| Stranded steering | `SessionFeatureRun.kt` (`sendStrandedSteer`), `SessionFeaturePendingInputs.kt` | `OpenCodeClient+Payloads.swift` (description only) | `SessionFeature.strandedSteer`, `strandedSteerTapped` | done for the model and action — queue→steer order, inbox refresh and 1.5 s run check; the queued-message sheet is P9. `strandedSteer` |
| Family and subagent pages | `LiveFamily.kt` (`requestSessionFamily`), `SessionPageStack.kt`, Home `subagentStack` | `SessionPageStack`/`Subagent` (description only) | `SessionFamily`, `SessionFamily.subagents`, `SessionPage`, `openSubagent`/`popPage` | done — bounded BFS, cycles ignored, family always discovered from its original root, inactive child clears its run, pages keyed by identity, covered answers preserved, return reads with `resume`. `SessionFamilyTests`, `familyIdentityAcrossPages` |
| Permission and form models | `server/model/PendingRequests.kt`, `Forms.kt` | `FormModels.swift` (description only) | `PermissionRequest`, `FormRequest`, `FormField`, `FormValue` | done — strict decode, `default`→default value, external false, conditions, hidden answers dropped, typed validation, global/mcp metadata. `RequestModelsTests` |
| Request review and settlement | `RequestReviewView.kt`, `RequestDockFeature.kt`, `RequestAnswer.kt`, `LiveRequests.kt` | `RequestReviewView.swift` (description only) | `SessionRequests`, `SessionFeature.replyPermission`/`submitForm`/`cancelForm`, `SessionView` review sheet | done for the P7 sheet — validation, Allow Once/Always/Deny, dismiss, one submission at a time, read-back settlement, conflict/expiry, actionable failure and retry; the composer dock is P9. `SessionUITests` |
| Pending inputs | `SessionFeaturePendingInputs.kt`, `LivePrompts.kt` | `OpenCodeClient+Payloads.swift` (description only) | `PendingInput`, `pendingInputs`, `setPendingInputDelivery` | partial — the inbox model, steer/queue and stranded send exist; the queued-message sheet and composer delivery controls are P9 |
| Background shell work | `BackgroundWorkPanel.kt`, `ShellOutputFeature.kt`, `LiveRequests.kt` | `SessionView.swift` (description only) | `SessionBackground`, `ShellOutputState`, shell operations | done for the panel — list running shells/jobs, 64 KiB pages, 256 KiB tail, 1 MiB retain, 4 MiB Load Earlier, 1 s poll, 3 s failure retry, 404 unavailable; polling starts when visible and loaded; ranges stay contiguous; stop drains to the probe boundary and a failed drain needs explicit discard; copy/share is P9/P10. `shellPollTiming`, `shellRangeContiguity`, `shellDrainAndFailure` |
| Job cancel | `SessionFeatureJobs.kt`, `LiveRequests.kt` | not recoverable | `jobCancelTapped`, `cancelJob` | done — idempotent cancel, stopping set, failure notice |
| Mark All | `HomeFeatureCatchUp.kt` (`MarkAllReadTapped`), `CatchUpFeature.acknowledgeViews` | `HomeFeature.swift` (description only) | `HomeFeature.markAllReadTapped`, `markAllReceiptFinished` | done — only `unread` indicators, attention/running untouched, four receipts at a time, per-session backup restored on failure, server-scoped keys. `markAllReadOnlyUnread`, `markAllFailureRestores` |
| Shell remains the only stream owner | `HomeConnectionFeature.kt`, `HomeFeatureServerEvents.kt` | `OpenCodeApp` (description only) | `ConnectionFeature.streamEvent` forwards every session-relevant event; App sends it to Home and the active session | done — queues, durable boundaries, reverts, shells and jobs cross the boundary; connection tokens still fence; no second subscription. `sessionEventForwarding` |
| Request/hints routes from Home attention | `live/LiveRequests.kt` | not recoverable | `Operations.pendingRequests`, `attentionSessionIDs` | done — the full models are P7; Home's loose root read is unchanged |

## Transcript (P8)

| Behaviour | Android source (`dev = 7358160e`) | Recovered iOS evidence | New path | Status |
| --- | --- | --- | --- | --- |
| Newest window, older cursor chain and one-message read | `server/live/LiveTranscript.kt` (`requestTranscript`, `requestHistoryPage`, `requestMessage`), `SessionFeatureHistory.kt` (`loadEarlierHistory`, `mergeOlderPage`, phases) | `OpenCodeClient+Transcript.swift` (description only) | `TranscriptOperations.swift`, `TranscriptState.EarlierHistory`, `SessionFeature.loadEarlierTranscript` | done — initial 30, history 80 with a 20 s allowance, overlap seeking, duplicate skip, same-cursor loop rejected, exhausted at the start; fenced by session + generation + cursor. `earlierHistory`, `earlierRetry`, `staleEarlierPage` |
| Message/part identity and REST merge | `LiveTranscript.kt` (`transcriptItems`), `SessionFeatureStream.kt` (`mergeTranscript`) | `OpenCodeTranscriptItem.swift` (description only) | `TranscriptModels.swift`, `TranscriptDecoder.swift`, `TranscriptProjection.mergeNewest` | done — deterministic `<message>-text-<n>`/`<message>-tool-<id>` IDs; assistant and shell rows; trimmed Markdown; strict id/type decode; older prefix retained; in-progress parts survive a snapshot; complete page replaces the transcript. `TranscriptDecodingTests`, `mergeNewest`, `inProgressSurvives` |
| Live delta and tool projection | `SessionFeatureStream.kt` (event application), `EventBatcher.kt` | `OpenCodeClient+Events.swift` (description only) | `TranscriptProjection.apply`, `SessionFeature.applyLiveTranscript` | done — text deltas append, ended text is durable, tool lifecycle upserts one row, reasoning events add no row, 600-token tail kept; batcher coalesces adjacent deltas before the reducer. `streamTailGate`, `streamedTail`, `toolLifecycle`, `emptyAndReasoning` |
| Grouping, reply Copy and disclosure | `TranscriptEntry.kt` (`TranscriptEntry.build`, `entryStart`, `sessionStartModelIDs`, `tail`) | `TranscriptEntry.swift` (description only) | `TranscriptGrouping`, `TranscriptState.entries`, `TranscriptView` | done — tools/notices group, user rows group per prompt, reply end only when settled, session-start model switch hidden, running question not history, stable entry IDs. `TranscriptGroupingTests.grouping`, `replyEndWaits`, `pendingQuestion`, `startModel`, `thousandRows` |
| Markdown blocks and plain fallback | `markdown/*` (`OpenCodeMarkdownBlock`, `InlineMarkdownParser`, `MarkdownStream`, `MarkdownTailHeal`, tables, tasks, math) | `MarkdownBlockView.swift` (historical) | `OpenCodeTranscript/Markdown.swift`, `ios/OpenCode/Transcript/MarkdownViews.swift` | done for the audited constructs — headings, paragraphs, lists/tasks, quotes, fenced code, tables, rules, image links and display-math source; malformed content stays text; inline formatting uses Foundation. Math/Mermaid typesetting is P10. `MarkdownTests` |
| Scrolling: follow, jump, earlier anchor, per-page restore | `list/TranscriptList.kt`, `TranscriptListScroller.kt`, `SessionFeatureStateTranscript.kt` | `TranscriptListViewController.swift` (historical) | `TranscriptView`, `TranscriptState.scrollAnchorID/isFollowing/expandedIDs` | done — follows at the end through text/tool/Markdown height growth, stops only on a reader drag, Jump to Latest when browsing, prepend anchor restored, disclosure and position survive a covered subagent page; Reduce Motion drops the jump glide. `pageRestoration`, `testFollowingSurvivesTailGrowthAndBrowsingHoldsItsAnchor` |
| Content safety | `BrowserLinkPolicy`, `MarkdownLinks`, link menu | `LinkMenu.swift`/`BrowserFeature` (description only) | `TranscriptCopy` link confirmation, `OpenURLClient`, image cards | done — links never open on their own; http/https/mailto only; Copy Link available; remote images are link cards with no fetch; server text is rendered as text. `copyAndLinks`, `testLinkConfirmationNeverOpensOnItsOwn` |
| Selection and copy | `selection/TranscriptReplySelection.kt`, `TranscriptUserBubble` | `TranscriptReplySelectionView.swift` (historical) | `.textSelection(.enabled)`, reply Copy, code Copy | partial — native per-block selection and explicit reply/code Copy; the cross-block single-document selection is not rebuilt (D-62) |
| Off-screen pressure and parse cache | `EventBatcher` shedding, `MarkdownStream`/cache hooks | `OpenCodeClient+Transcript.swift` LRU 16 | `MarkdownBlockCache` (256 entries / 4 MiB), visible-row parsing, batcher coalescing, `MarkdownBlockPresenter` revision fencing | done — adjacent deltas coalesce; only visible Markdown rows parse off-main; a late parse cannot publish over newer text or a replaced row; the cache is bounded and clears on memory warning. Raced replay over 512 batches stores a persistent recovery with bounded attempts, not silent loss. `cacheBounds`, `latestParseWins`, `staleBlocksClear`, `disappearanceFencesPublication`, `overflowSettlementDelaysRecovery`, `failedRecoveryStaysRequired` |

### Transcript evidence freshness

- Baseline behaviour source: `dev = 7358160e`. The audited transcript files last changed at
  `LiveTranscript.kt`/`OpenCodeTranscriptItem.kt` `a2e77d9e` (2026-11-16), `OpenCodeToolCall.kt`
  `56b5fbe8` (2026-11-15), `TranscriptEntry.kt` `0091811a` (2026-11-15), `TranscriptList.kt` `18280423`
  (2026-11-14) and `SessionFeatureHistory.kt` `fac20b68` (2026-11-19). None is older than the parity sync
  at iOS `01eef583` in a way that changes the adopted rows; no current `dev` transcript change was skipped.
- Historical iOS file names and October screenshots are evidence only. The October capture harness names
  `transcript-list` and `tool-image-mosaic` are reused as identifiers where they still describe the UI.

## Deliberate divergences

Recorded here so they are not mistaken for missing work.

| Item | Android behaviour | New iOS decision |
| --- | --- | --- |
| Typography | Inter + OpenMono, desktop scale | SF + SF Mono (D-1) |
| Motion curves | Compose springs from `(duration, bounce)` via `ω = 2π/duration` | Same role names and numbers; SwiftUI's perceptual `duration`/`bounce` (D-18) |
| Haptics | Composed vibrator primitives with a predefined fallback | UIKit feedback generators mapped from the same vocabulary (D-19) |
| Transcript motion | bottom-anchored `LazyColumn`, no follower | SwiftUI `ScrollView` + `LazyVStack`: follow at the end, Jump to Latest when browsing, no UIKit follower, row growth or send flight (D-59) |
| Photo picking | system picker | system picker proposed; no in-app photo sheet |
| Autocomplete | list, next-frame filtering | SwiftUI-native list |
| Quotes | quote cards above the bubble | adopted as display-only quote cards; quote-to-composer is P9 (D-60) |
| Notifications | FCM, relay absent | Experimental, off until a relay exists |
| Redirect tests | OkHttp interceptor + MockWebServer | pure `HTTPRedirectRule` plus a loopback HTTP server that exercises the real URLSession delegate (D-22, D-28) |
| Cleartext | manifest cleartext plus an interceptor | ATS exceptions plus `TransportSecurity`, both narrower than "cleartext everywhere" (D-22) |
| Time in retries | `Clock` dependency over coroutines | `ClockClient` with recording/gated doubles (D-21) |
| Local-network denial | Android 17 permission preflight with a dedicated denial message | iOS does not expose a preflight; the shell shows a generic unreachable message plus a Local Network settings hint, never a denial claim (D-35) |
| Storage identity | Android application id + keys | Keychain service derived at runtime from the configured bundle identifier; no historical identifier copied (D-32) |
| Connected destination | Home drawer and session list | P7 shows Home, the drawer and a session screen with metadata, Stop, subagents, requests and background work; transcript/composer are P8/P9 (D-36 superseded by D-43, D-53) |

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
| Home reducer and persistence | `OpenCodeDrawerTests/HomeFeatureTests.swift` | done — 38 tests covering pins, unread, server isolation, visibility, search/paging retries, stale responses, read watermarks, **Mark All**, targeted deletion verification/tombstones/late results, Catch Up, What's New, snapshot bounds/versioning/migration and cold attention |
| Session reducer, run lifecycle, family, requests, shells | `OpenCodeSessionTests/SessionFeatureTests.swift` | done — 25 tests: refresh coalescing, snapshot/event race, settlement window, interrupt ambiguity/resume, stranded steer, validation, duplicate submit, conflict, permission rules, root/child/sibling navigation with family identity, uncached load/retry/reconnect, stale read, shell poll timing, contiguous/bounded ranges, drain/failure/cancellation at page and probe with a successful control |
| Request models | `OpenCodeServerTests/RequestModelsTests.swift` | done — value order, defaults/visibility, typed validation, hidden answers, strict type, global question |
| Family discovery | `OpenCodeServerTests/SessionFamilyTests.swift` | done — BFS order, cycle/dedupe, 100-session cap, running descendant |
| App → Session ownership and stream forwarding | `OpenCodeAppTests/AppFeatureTests.swift` | done — child identity, replacement, server isolation, and App/Connection forwarding of shell, job, inbox, durable content, revert and shell-ended events into Session |
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
| Server: transcript decoding and routes | `.../TranscriptDecodingTests.swift` | done — 11 tests: user references/quotes/images, assistant ordinals/tools, shell rows, newest-first ordering, run errors, notices, malformed payloads, bounds, all three routes |
| Transcript grouping and projection | `OpenCodeTranscriptTests/TranscriptTests.swift` | done — 26 tests: grouping, pending questions, start model, entry start, 1,000 stable identities, newest/older merges, streaming tail, tool lifecycle, Markdown blocks, copy text and cache bounds |
| Transcript in the session | `OpenCodeSessionTests/TranscriptFeatureTests.swift` | done — 19 tests: read plan, empty/failure, live + settlement, event race, invalidation, earlier history/retry, stale generation, reconnect, page restoration, copy/link safety, 600-token tail and 1,000 rows |
| Server: client requests | `.../OpenCodeClientTests.swift` | done |
| Bounded channel | `OpenCodeCoreTests/BoundedChannelTests.swift` | done; one pre-existing timing-sensitive expectation flaked once and passed on rerun |
| UI (XCUITest) | `OpenCodeUITests/{LaunchSmokeTests,ConnectionLifecycleUITests,KeychainProbeTests,SavedServerProbeTests,HomeUITests,HomeScreenshotUITests,HomeScrollTraceUITests,SessionUITests,SessionScreenshotUITests,TranscriptUITests,TranscriptScreenshotUITests,TranscriptScrollTraceUITests}.swift` | done — 46 tests; P8 adds nine transcript journeys, light/dark/tool screenshots and two simulator scroll traces |
