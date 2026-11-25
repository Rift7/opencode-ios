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
  (PR #5); P7 as `92a7c677` (PR #6); P8 as `2823c06e` (PR #7, tree `1147dca8`); P9 as `e42cb455`
  (PR #8, tree `62d44987`). P10 branched from `e42cb455` as `ios-media`.

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
| Keychain | `core/.../sharing/LiveSharedBytes.kt` | `Core/Keychain.swift` | `.../Storage/{KeyValueStorage,KeychainStorage}.swift` | done — typed `value`/`missing`/`failure` outcomes, failure mapping unit-tested, round-trip verified in the signed app process and saved credentials/headers restored across relaunch on device |
| Semantic colour tokens | `core/.../ui/{BrandPalette,OpenCodeColors}.kt` | `Core/Theme/Theme.swift` (system colours) | `.../Design/OpenCodeColorTokens.swift` | done |
| Type tokens | `core/.../ui/OpenCodeTypography.kt` | system text styles | `.../Design/OpenCodeTypeTokens.swift` | done |
| Spacing and radius tokens | `core/.../ui/OpenCodeShapes.kt` (`OpenCodeSpacing`, `OpenCodeRadius`, `OpenCodeShapeGeometry`) | not recoverable — native decision (D-17) | `.../Design/OpenCodeLayoutTokens.swift` | done — grid, radius scale and corner clamp tested |
| Motion vocabulary | `core/.../motion/{MotionRole,MotionConstants,MotionReduce}.kt` | not recoverable — native decision (D-18) | `.../Motion/OpenCodeMotion.swift` | done — fourteen roles, per-phase curves, Reduce Motion collapse, pose and stagger tested; no screen animates yet |
| Logging | `core/.../log/AppLog.kt` | `Core/AppLog.swift` | `.../Logging/AppLog.swift` | scaffold — structured public fields only (numbers/booleans), free text private; not the full Android journal |
| Test isolation and network guard | (test-only `TestNetworkBlock`) | `TestIsolationGuard` | `.../OpenCodeTestSupport` | done — isolated storage, network guard, and a transport seam whose test value blocks |
| Preview states | n/a | SwiftUI previews | `ios/OpenCode/App/RootView.swift` (`#Preview` × 2) | scaffold |
| Haptics vocabulary | `core/.../haptics/HapticsClient.kt` | not recoverable — native decision (D-19) | `.../Haptics/HapticsClient.swift` | done for the seam and vocabulary; all eleven verified on a physical iPhone (distinct; `tap` lighter than warning/error) |

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
| Network path | `server/retry/NetworkPath.kt` | `NetworkPath.swift` | `OpenCodeCore/Network/NetworkPathClient.swift` | done for observation, offline/wait and reroute-driven reconnect; foreground/background plus real socket-loss recovery verified on device, radio-path change not separately exercised |
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
| Composer, pending inputs | `feature/composer/.../ComposerTextInput.kt`, `ComposerPersistence*.kt`, `RequestDockFeature.kt`, `QueuedMessagesSheet.kt` | `ComposerTextInput.swift`, `RequestReviewView.swift`, `QueuedMessagesSheet.swift` | `.../OpenCodeComposer`, `ios/OpenCode/Composer` | **done for P9 scope** — see the Composer section below; model/agent/mentions are P11; attachments are P10 |
| Media, agent files, browser | `feature/media/.../` | `Media/`, `Browser/` | `.../OpenCodeMedia`, `ios/OpenCode/Media` | **done for P10 scope** — imports/uploads, viewers, server file reads, annotation, browser gate, bounded caches; folder-browser UI and picker videos deferred |
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
| Markdown blocks and plain fallback | `markdown/*` (`OpenCodeMarkdownBlock`, `InlineMarkdownParser`, `MarkdownStream`, `MarkdownTailHeal`, tables, tasks, math) | `MarkdownBlockView.swift` (historical) | `OpenCodeTranscript/Markdown.swift`, `ios/OpenCode/Transcript/MarkdownViews.swift` | done for the audited constructs — headings, paragraphs, lists/tasks, quotes, fenced code, tables, rules, image links and display-math source; malformed content stays text; inline formatting uses Foundation. Math/Mermaid keep the P10 source fallback (D-87). `MarkdownTests` |
| Scrolling: follow, jump, earlier anchor, per-page restore | `list/TranscriptList.kt`, `TranscriptListScroller.kt`, `SessionFeatureStateTranscript.kt` | `TranscriptListViewController.swift` (historical) | `TranscriptView`, `TranscriptState.scrollAnchorID/isFollowing/expandedIDs` | done — follows at the end through text/tool/Markdown height growth, stops only on a reader drag, Jump to Latest when browsing, prepend anchor restored, disclosure and position survive a covered subagent page; Reduce Motion drops the jump glide. `pageRestoration`, `testFollowingSurvivesTailGrowthAndBrowsingHoldsItsAnchor` |
| Content safety | `BrowserLinkPolicy`, `MarkdownLinks`, link menu | `LinkMenu.swift`/`BrowserFeature` (description only) | `TranscriptCopy` link confirmation, `OpenURLClient`, image cards | done — links never open on their own; http/https/mailto only; Copy Link available; remote images are link cards with no fetch; server text is rendered as text. `copyAndLinks`, `testLinkConfirmationNeverOpensOnItsOwn` |
| Selection and copy | `selection/TranscriptReplySelection.kt`, `TranscriptUserBubble` | `TranscriptReplySelectionView.swift` (historical) | `.textSelection(.enabled)`, reply Copy, code Copy | partial — native per-block selection and explicit reply/code Copy; the cross-block single-document selection is not rebuilt (D-62) |
| Off-screen pressure and parse cache | `EventBatcher` shedding, `MarkdownStream`/cache hooks | `OpenCodeClient+Transcript.swift` LRU 16 | `MarkdownBlockCache` (256 entries / 4 MiB), visible-row parsing, batcher coalescing, `MarkdownBlockPresenter` revision fencing | done — adjacent deltas coalesce; only visible Markdown rows parse off-main; a late parse cannot publish over newer text or a replaced row; the cache is bounded and clears on memory warning. Raced replay over 512 batches stores a persistent recovery with bounded attempts, not silent loss. `cacheBounds`, `latestParseWins`, `staleBlocksClear`, `disappearanceFencesPublication`, `overflowSettlementDelaysRecovery`, `failedRecoveryStaysRequired` |
| Inline images, tool mosaics, file cards and viewers | `user/MediaReferenceTiles.kt`, `rows/ToolImages.kt`, `user/UserAttachmentViews.kt`, `MediaPresentation.kt` | `TranscriptEntryView.swift` (description only) | `OpenCodeMedia`, `ios/OpenCode/Media`, `ios/OpenCode/Transcript/TranscriptRows.swift` | done for P10 — native image tiles, a tool mosaic, a gallery with zoom/pan, video/audio/PDF/code/text pages, loading/retry/unavailable, stable image identity; per-block selection remains |

### Transcript evidence freshness

- Baseline behaviour source: `dev = 7358160e`. The audited transcript files last changed at
  `LiveTranscript.kt`/`OpenCodeTranscriptItem.kt` `a2e77d9e` (2026-11-16), `OpenCodeToolCall.kt`
  `56b5fbe8` (2026-11-15), `TranscriptEntry.kt` `0091811a` (2026-11-15), `TranscriptList.kt` `18280423`
  (2026-11-14) and `SessionFeatureHistory.kt` `fac20b68` (2026-11-19). None is older than the parity sync
  at iOS `01eef583` in a way that changes the adopted rows; no current `dev` transcript change was skipped.
- Historical iOS file names and October screenshots are evidence only. The October capture harness names
  `transcript-list` and `tool-image-mosaic` are reused as identifiers where they still describe the UI.

## Composer (P9)

| Behaviour | Android source (`dev = 7358160e`) | Recovered iOS evidence | New path | Status |
| --- | --- | --- | --- | --- |
| Text, selection, IME and hardware Return | `ComposerTextInput.kt` (`ImagePasteTextView`, `syncText`, `finishCompositionIfNeeded`, `ComposerSavedSelection`, keyboard preview handling) | `ComposerTextInput.swift` (description only) | `ios/OpenCode/Composer/ComposerTextInput.swift` | done for the bridge — `UITextView` preserves marked text against external sync, clamps selection, grows to 168 pt, sends on Return when Return Sends is enabled and inserts a newline on Shift+Return; Japanese marked text and chip editing verified on device; hardware Shift+Return blocked (no keyboard) |
| Draft scope, debounce, flush, outbound ownership and bounds | `ComposerPersistence*.kt` (`composer-state.json`, 500 ms, server+session keys, New Session project, 30-day staleness) | `ComposerPersistence.swift` (description only) | `OpenCodeComposer/ComposerDraftStore.swift`, `ComposerFeature` | done — server+session / server+project keys; 500 ms reducer debounce; explicit Done/background flush; 128 KiB text, 64 KiB quotes, 200 quotes; failed sends and the in-flight outbound record are persisted; unresolved outbound restores as an unverified failed send with its original ID; failure and too-large are typed, no truncation |
| Send eligibility, durable outbound, first-send creation, duplicate protection | `SessionFeatureSend.kt` (`sendComposer`, `submit`, `SendTapped`), `HomeFeatureDrawer.kt` (`NewSessionTapped`) | `SessionFeature.swift` (description only) | `ComposerFeature`, `SessionFeature.startComposerSend`, Home `newSessionTapped` | done — the outbound record is written before dispatch; a save failure does not send; one in-flight send; `POST /api/session` with a client id before the prompt; created session retained on prompt failure |
| Message IDs, failure recovery, retry, restart reconciliation | `SessionFeatureDelivery.kt` (`serverHas`, send backoff), `LivePrompts.kt` (idempotent prompt ID) | `SessionFeature.swift` (description only) | `ComposerFeature.failedSends`, `SessionFeature.composerSendResult`, `reconcileMessage` | done with the recorded P9 gate — definite rejection can retry under a new ID that is durably recorded before dispatch; ambiguous read-back settles or reports unverified; a retry mints a new ID only after a successful read-back confirms the old ID absent, then persists it before the prompt; an outbound record left by termination reopens as unverified and preserves its actual ID/target; results never fall back to another outbound record |
| Experimental wait loop | `LiveSessions.kt` (`requestWaitForIdle`, 25 s poll, 12 fast failures, active probe, `.once` caller escape) | not recoverable | `OpenCodeServer/Retry/SessionWaitLoop.swift`, `PromptOperations.waitForIdle` | done — one retry owner, cancellable, re-arms a timed-out live run immediately; completion schedules the existing settlement read |
| Queued inputs and steer | `SessionFeaturePendingInputs.kt` (inbox, delivery override, cancel, stranded steer), `QueuedMessagesSheet.kt` | `OpenCodeClient+Payloads.swift` (description only) | `SessionFeature` inbox actions, `QueuedInputsSheet` | done — P7 inbox remains the only model; Send Now/move/cancel; idle messages reuse queue-then-steer; late inbox results are session-fenced |
| Request dock | `RequestDockView.kt`, `RequestAnswer.kt`, `RequestCollapse.kt` | `RequestReviewView.swift` (description only) | `RequestDockState`, `RequestDockPanel`, `RequestAnswerBar`; P7 sheet retained | done for the audited fold/question/answer-bar scope — permissions and simple forms dock, larger forms keep the sheet; keyboard Send routes to the request, never chat; the chat draft is untouched |
| Quote handoff | `ComposerQuote.kt`, `ComposerQuoteViews.kt`, `PromptBody.Metadata.comments` | quote cards only | `ComposerQuote`, `ComposerSend.prompt`, `QuoteSelectionSheet` | done for one block — native selection text and optional comment become the model block plus `metadata.comments`; cross-block selection remains P8/P14 |
| Subagent page composer | `SessionPageStack.kt`, `SessionFeature` | `SessionFeature.swift` (description only) | `SessionFeature` page targets, `ComposerFeature.switchTarget` | done — child pages keep their own drafts/quotes and send to the child session ID; a completed send resolves its original target when another page is visible; `subagentDraftOwnership`, `sendCompletesOnAnotherPage` |
| Dismissal and replacement | `SessionView`, `AppFeature` session removal | `SessionFeature.swift` (description only) | `AppFeature` pending dismissal and draft transfers, `SessionFeature.flushForDismiss` | done — explicit flush completion with session identity and request ID; the composer re-saves newer text/quotes/failed/outbound content before reporting saved; a failed save keeps the session; replacement/switch/disconnect/interactive dismissal transfer the draft outside the child lifetime; a failed transfer is retained under its key, surfaced as `draftKept`, and retried on launch/foreground/navigation; `saveIfNewer` fences by timestamp then revision; fourteen `AppDismissalTests` |
| Long input | `ComposerTextInput.kt` | `ComposerTextInput.swift` (description only) | `ios/OpenCode/Composer/ComposerTextInput.swift` | done — grows to 168 pt then scrolls internally with the caret/selection visible; shrinking restores the non-scrolling layout; UI long-draft accessibility journey |
| Model/agent/mode, autocomplete, mentions and commands | `ModelPicker*`, `AgentPicker`, `AutocompleteFeature.kt`, `ComposerAutocomplete*` | not recoverable | `ComposerAutocomplete.swift`, `ComposerViews.swift`, `SessionFeature.startComposerSend` | **done for P11** — model/agent/reasoning picker, skill/agent/file/command suggestions, UTF-16 mention ranges and durable selection; session mentions remain deferred |
| Attachments, photos, files and camera | `ComposerAttachmentsFeature.kt`, `AttachmentPicker.kt`, `ComposerPhotoViewer.kt` | `Media/` (description only) | `OpenCodeMedia`, `ios/OpenCode/Composer` | **done for P10** — Photos/Files/Camera/Paste, staged copies, progress/retry/removal, persisted attachment references, inline/path prompt encoding, preview and annotation; picker videos deferred |

## Media (P10)

| Behaviour | Android source (`dev = 7358160e`) | Recovered iOS evidence | New path | Status |
| --- | --- | --- | --- | --- |
| Photo, document, camera and paste import | `ComposerImageImport.kt`, `ComposerFileImport.kt`, `ComposerFileStaging.kt`, `PastedTextViews.kt` | `ComposerPhotoViewer.swift`, `AttachmentCameraView.swift` (description only) | `OpenCodeMedia/MediaImport.swift`, `MediaFileStore.swift`, `ComposerViews.swift`, `CameraCaptureSheet.swift` | done — photos (images), files, camera and paste; 20 MB image/100 MB file bounds, actual-byte MIME and JPEG re-encode; system photo/camera UI |
| Upload, progress, retry and unsupported | `ComposerAttachmentsFeature.kt` (`upload`, `cancelUpload`), `LiveFiles.kt` (`uploadFile`) | `ComposerFileAttachment.swift` (description only) | `MediaOperations.uploadFile`, `ComposerFeature` upload effects | done — `paths.tmp` discovery, attachment-ID path stable across retries, throttled progress, originating-key/attempt fencing, hidden-draft merge, failure/retry and interrupted restore; live upload unverified |
| Durable attachment ownership | `ComposerPersistence*.kt` (`ComposerAttachments/`, `composer-state.json`) | `ComposerPersistence.swift` (description only) | `ComposerDraft.attachments`, `FailedComposerSend`, `ComposerOutbound`, `releaseIfUnreferenced` | done — draft/failed/outbound references; removal keeps a file another record owns; legacy drafts decode |
| Prompt encoding | `PromptBody`/`OpenCodePromptPresentation` | `OpenCodeClient+Payloads.swift` (description only) | `ComposerSend.prompt(inlineData:)` | done — inline `data:` parts, path reference lines, `metadata.attachments` and `comments` |
| Transcript image tiles, tool mosaic, gallery and viewers | `user/MediaReferenceTiles.kt`, `rows/ToolImages.kt`, `MediaPresentation.kt`, `FullscreenViewer.kt`, `ZoomableImagePage.kt` | `FullscreenViewer.swift`, `ZoomableImagePage.swift` (description only) | `MediaViewerFeature`, `MediaViewerView`, `TranscriptRows.swift` | done — gallery/page identity, zoom/pan, drag dismiss, video/audio/PDF/code/text, retry/unavailable |
| Media blob cache | `MediaReferenceClient.kt` (48 MiB/64, 25 MiB blob, per-server 404), `media-cache-limit` branch | `MediaReferenceClient.swift` (description only) | `MediaReferenceCache` | done — authentication-scoped 256 MiB disk cap, SHA-256 admission, finished-blob trim, coalescing, memory warning, 64 MiB decoded cache |
| Server file reads and code preview | `agentfiles/AgentFileLoader.kt`, `AgentTextDocument.kt`, `SyntaxHighlighter.kt` | `AgentFileViewer.swift` (description only) | `FileViewerFeature`, `CodePreview`, `FileViewerView` | done for referenced files — `fs/list`/`fs/read`, remote-only paths, 2 MiB reads, bounded code lines/tokens; folder-browser UI deferred |
| Image annotation | `ImageDrawing.kt`, `ImageDrawingEditor.kt` | `ImageDrawingEditor.swift` (description only) | `MediaAnnotation.swift`, `AnnotationEditor.swift` | done — normalized strokes, six inks, undo, flatten and return; original unchanged on cancel |
| Browser | `browser/BrowserFeature.kt`, `BrowserLinkPolicy.kt`, `BrowserWebViews.kt` | `BrowserFeature.swift`, `BrowserView.swift` (description only) | `BrowserFeature`, `BrowserPolicy`, `BrowserSheet` | done for the audited boundary — Experimental off, public pages only, non-persistent store, handoff/fallback, no credentials/script bridge; Ask deferred |
| Math and Mermaid | `markdown/MathSyntax`, `mermaid/*` | `Mermaid/*` (description only) | — | final source fallback (D-87) — not rendered |
| Cross-block selection | `selection/TranscriptReplySelection.kt` | `TranscriptReplySelectionView.swift` (description only) | per-block `.textSelection`, reply Copy | partial — deferred to P14 |
| Background subagent stop, shell copy/share | `SessionFeatureJobs.kt`, `ShellOutputFeature.kt` | `SessionView.swift` (description only) | `SessionFeature.backgroundSubagentStopTapped`, shell toolbar | done — subtree interrupt/job cancel tested; shell Copy/Share use the existing dependencies |

## Deliberate divergences

Recorded here so they are not mistaken for missing work.

| Item | Android behaviour | New iOS decision |
| --- | --- | --- |
| Typography | Inter + OpenMono, desktop scale | SF + SF Mono (D-1) |
| Motion curves | Compose springs from `(duration, bounce)` via `ω = 2π/duration` | Same role names and numbers; SwiftUI's perceptual `duration`/`bounce` (D-18) |
| Haptics | Composed vibrator primitives with a predefined fallback | UIKit feedback generators mapped from the same vocabulary (D-19) |
| Transcript motion | bottom-anchored `LazyColumn`, no follower | SwiftUI `ScrollView` + `LazyVStack`: follow at the end, Jump to Latest when browsing, no UIKit follower, row growth or send flight (D-59) |
| Photo picking | system picker | System `PhotosPicker`; no in-app photo sheet (D-78) |
| Camera | in-app CameraX sheet with lenses/zoom/lock | System camera capture bridge; typed permission/unavailable states (D-78) |
| Media viewer motion | animated frame/rounded clip, predictive back | Native full-screen gallery and short drag dismissal; no flight or predictive-back morph (D-82) |
| Upload resume | none (same path retry) | same path retry, no resume; interrupted upload restores as a retryable failure (D-80) |
| Browser | in-app WebView behind a setting | Experimental WKWebView, off by default, non-persistent and public-only (D-85) |
| Math/Mermaid | jLaTeXMath and a WebView Mermaid renderer | source fallback only (D-87) |
| Autocomplete | list, next-frame filtering | SwiftUI-native list |
| Quotes | quote cards above the bubble | quote cards plus a one-block native selection handoff into the composer (P9, D-60/D-69); cross-block selection remains deferred |
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
| Composer state and drafts | `OpenCodeComposerTests/{ComposerFeatureTests,ComposerDraftStoreTests}.swift` | done — 26 tests: scoped restore, delayed race, failed save, size bound, duplicate tap, newer typing, unverified, failure recovery, quote metadata, outbound restart, blocked sends, target switching, migration outcomes, destination-first migration, revision/timestamp fencing, legacy decoding |
| Composer sends, inbox, dock, quote in the session | `OpenCodeSessionTests/ComposerSessionTests.swift` | done — 22 tests: first-send creation, duplicate protection, create-then-fail, ambiguous found/unreadable, new-ID retry with durable identity, typing, queue/steer/cancel, question/permission dock, quote handoff, subagent drafts and targets, restart reconciliation, suspended retry restart, send completion on another page |
| Composer routes and wait loop | `OpenCodeServerTests/{ComposerClientTests,SessionWaitLoopTests}.swift` | done — 4 route/body tests and 5 bounded wait tests (immediate re-arm, backoff, inactive run, caller-owned retry, 12-failure bound) |
| Media imports, staging, paths, caches, code preview, annotation, browser policy and file viewer | `OpenCodeMediaTests/MediaTests.swift` | done — 30 tests: image downscale/oversize/corrupt, file sniff/oversize, paste, long-paste trigger, attachment round-trip, remote path resolution, hash validation, scratch/imported-suffix cleanup, blob coalescing/scope/mismatch/corruption/404/disk trim, browser policy/navigation, code bounds, annotation flatten, file viewer read |
| Composer attachments, upload ownership and retry | `OpenCodeComposerTests/ComposerAttachmentTests.swift` | done — 18 tests: legacy decode, round-trip, import/send, failed upload/retry, prompt encoding, durable release after save, failed save/removal, restart, outbound and viewer ownership, target fence, navigation completion, retry attempt fencing, deferred merge, remove-during-upload, limit |
| Media routes and download bounds | `OpenCodeServerTests/{MediaClientTests,MediaDownloadBoundTests}.swift` | done — 9 tests: blob capability/auth, stable upload path/progress, unsupported, file read/list bound, and loopback declared/chunked/understated overflow, close/cancellation and within-bound reads |
| Session media and subagent stop | `OpenCodeSessionTests/SessionMediaTests.swift` | done — 4 tests: image gallery, file viewer, subtree stop, browser gate |
| Server: client requests | `.../OpenCodeClientTests.swift` | done |
| Bounded channel | `OpenCodeCoreTests/BoundedChannelTests.swift` | done; one pre-existing timing-sensitive expectation flaked once and passed on rerun |
| UI (XCUITest) | `OpenCodeUITests/{LaunchSmokeTests,ConnectionLifecycleUITests,KeychainProbeTests,SavedServerProbeTests,HomeUITests,HomeScreenshotUITests,HomeScrollTraceUITests,SessionUITests,SessionScreenshotUITests,TranscriptUITests,TranscriptScreenshotUITests,TranscriptScrollTraceUITests,ComposerUITests,ComposerScreenshotUITests,MediaUITests,MediaScreenshotUITests,MediaPerformanceUITests}.swift` | done — 70 tests; P10 adds eight media journeys (gallery, tool mosaic, file preview, browser gate, paste preview/remove, pasted-image send, annotation return, Dynamic Type/dark, relaunch recovery), 16 light/dark screenshots and three performance traces |


## Settings, catalogue, pairing and composer context (P11)

| Behaviour | Android source (`dev = 7358160e`) | Recovered iOS evidence | New path | Status |
| --- | --- | --- | --- | --- |
| Settings stack, typed defaults and persistence | `SettingsFeature.kt`, `HomeSettingsFeature.kt`, `SharedKeys.kt` | `SettingsFeature.swift` (description only) | `OpenCodeSettings/SettingsFeature.swift` | done — full-screen stack; six typed keys; failed writes surfaced; delayed restore cannot overwrite an edit |
| Appearance and supported preferences | `AppearanceSettingsView.kt`, `SessionsSettingsView.kt` | settings captures (secondary) | `SettingsView.swift`, `OpenCodeApp.swift` | done for System/Light/Dark and the audited Return/Wrap keys; language/themes/sidebar/voice preferences are not inherited |
| Experimental switches | `ExperimentalSettingsView.kt`, `ExperimentalFeature.kt` | `ExperimentalSettingsView.swift` (description only) | `SettingsView.swift`, `SharedKeys.experimentalInAppBrowser` | done for In-App Browser, off by default; other experiments have no iOS owner and are not displayed |
| Server editing and custom headers | `AppFeature.kt`, `OpenCodeServer.kt` | manual server form (description only) | `SettingsFeature`, `ServerEditForm`, `OpenCodeServer.Header` | done — name/value/forbidden-header validation, Keychain write only after success, prior config retained on failure, headers origin-bound and cache-scope-aware |
| Diagnostics and copied report | `ProblemReport.kt`, `DiagnosticsJournal.kt` | copy report (description only) | `DiagnosticFacts`, `DiagnosticReport` | done — allow-listed typed facts, user-initiated, fixed order; adversarial privacy test |
| Onboarding/help | `WelcomeFeature.kt`, `WelcomeView.kt` | welcome captures (secondary) | `SettingsView.onboardingPage/helpPage` | done — three-step guide and help without credentials or hardware |
| QR pairing presentation | `PairingScanner.kt`, `ServerCameraClient.kt`, `QRCameraPreview.kt` | scanner description only | `PairingScannerClient`, `QRCameraScanner`, `PairingCaptureView` | done — initial setup and Settings both reach the scanner; physical capture, confirmation before redemption, exactly-once redemption, expired-code copy and denial state verified on device; restricted/unavailable unverified |
| Shipped What's New catalogue | `whatsnew/entries/*.kt` (182 files), `WhatsNewEntries.kt` | row/page capture only | `WhatsNewCatalogue.swift`, `WhatsNewView` | done — IDs/days/copy reconstructed; seen state retained; Try It works or is explicitly unavailable |
| Model catalogue and reasoning variants | `LiveCatalog.kt`, `Models.kt`, `ModelPicker*` | `ModelPicker` description only | `ModelCatalog.swift`, `CatalogOperations.swift`, picker sheet | done in fixtures — `/api/model`, optional `/api/model/default`, `/api/agent`, variant ordering and short names |
| Agent/mode selection | `AgentPicker.kt`, `LiveCatalog.kt` | description only | `ServerAgent`, agent picker | done — choosable primary/all, server-default choice |
| Apply selection before send | `ComposerFeature.send`, `SessionFeatureDelivery.kt` | not recoverable | `SessionFeature.startComposerSend` | done — agent then model once before the prompt; queued sends do not switch; refusal fails the send; configuration snapshotted in the outbound record |
| File/agent/skill/command autocomplete | `AutocompleteFeature.kt`, `AutocompleteModels.kt` | description only | `ComposerAutocomplete.swift`, `ComposerViews.swift` | done — UTF-16 triggers, bounded rows, generation fences, IME composition guard; Japanese marked text and real LAN suggestion insertion verified on device |
| Mentions and prompt encoding | `ComposerAutocomplete*.kt`, `OpenCodeAutocompleteMentions` | not recoverable | `ComposerMentionBuilder`, `PromptBody` mention fields | done for agents/skills/files; session mentions deferred |
| Remote folder browser | `FolderBrowserFeature.kt`, `DraftProjects.kt`, `LiveFiles.kt` | description only | `FolderBrowserFeature.swift`, `FolderBrowserView.swift` | done — on-demand `fs/list`, remote-only paths, loading/retry/empty/error, back/cancel and draft-preserving selection |

### P11 freshness

- Settings and experimental registry last changed at `bc68c787` (2026-11-16); server form/headers at
  `9b4e1d9c` (2026-11-20); diagnostics at `24c96b93` (2026-11-18); catalogue/autocomplete/folder
  browser at `f79a895e` (2026-11-14). All precede the behaviour baseline `7358160e` (2026-11-21), so
  current `dev` is the adopted source.
- Physical behaviour (camera, permission prompts, Keychain on a signed build, IME and haptics) has no
  simulator proof and is listed in `P12_DEVICE_CHECKLIST.md`.


| Settings, diagnostics, onboarding and pairing presentation | `OpenCodeSettingsTests/SettingsFeatureTests.swift` | done — 13 cases: defaults, restore race, failed write, experiment change, header policy, invalid form, save failure, diagnostics privacy, offline onboarding, scan once, camera denial, cache scope, payload decode |
| Model/agent selection payload and refusal | `OpenCodeSessionTests/SessionSelectionTests.swift` | done — agent then model then prompt order; refused switch posts nothing; configuration preserved |
| Autocomplete and mentions | `OpenCodeComposerTests/ComposerAutocompleteTests.swift` | done — 8 tests: trigger boundaries, committed chips, bounded rows, UTF-16 apply, wire ranges/URI, stale token drop, prompt fields |
| Remote folder browser | `OpenCodeSessionTests/FolderBrowserTests.swift` | done — 5 tests: on-demand reads, cached back, typed failure/retry, ancestors, draft-preserving selection |
| Catalogue client routes | `OpenCodeServerTests/CatalogClientTests.swift` | done — model/default decode/filter, optional default, model/agent switch bodies, agent/skill/command/find envelopes |
| Custom-header transport | `OpenCodeServerTests/ServerHeaderTransportTests.swift` | done — edited headers reach the wire, removed/forbidden/malformed ones do not, and credentials remain usable |
| What's New catalogue | `OpenCodeDrawerTests/WhatsNewCatalogueTests.swift` | done — 182 entries, unique IDs, newest-first, copy present, honest destinations |
| P11 UI | `OpenCodeUITests/{SettingsUITests,ComposerContextUITests,SettingsScreenshotUITests}.swift` | done — 9 journeys and 12 light/dark screenshots |

## Physical-device validation (P12)

The deferred P3–P11 device checks ran on the connected iPhone Air (iOS 27.3, 24C5049f; requested
27.2 unavailable) with Xcode 27.2/Swift 6.4.2 and the existing development signing. Full evidence is
in [DEVICE_VALIDATION.md](DEVICE_VALIDATION.md) and per-row results in
[P12_DEVICE_CHECKLIST.md](P12_DEVICE_CHECKLIST.md).

- Real LAN: connect, custom-header persistence/relaunch, Local Network denial/allow,
  foreground/background plus socket-loss recovery, one SSE stream per reconnect, and a refused
  cross-origin redirect with zero observer requests.
- Camera/QR: physical capture, confirmation before redemption, exactly-once redemption, expired
  code, and the camera-denied UI after the scanner-cover fix (D-107).
- Keychain: add/read/update/delete in the signed app and saved-server/header restoration across
  termination/relaunch.
- Input/accessibility: eleven haptics felt, VoiceOver walk by the owner, Japanese marked text
  suppressing suggestions until commit, real LAN suggestion insertion, selection/quote/copy,
  Dynamic Type and Reduce Motion settings.
- Share sheet: presented with synthetic file text; the system share-sheet process is outside the
  app's XCTest tree, so the evidence is manual.
- Not verified: camera restriction, photo/file provider permissions and eviction, playback
  interruption, hardware Shift+Return, real memory pressure, denied-Keychain write injection, and a
  compatible live-server read-only pass.
- Performance: Home 83–84.6 fps with 0 hitches; long transcript p95 25–26 ms and max 33–39 ms;
  streaming/media p95 16.7 ms; peak memory about 18.2–18.5 MB. These are device measurements, not
  the simulator numbers recorded earlier.
