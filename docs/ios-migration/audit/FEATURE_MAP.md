# FEATURE_MAP — feature → state → wire → failure, with source paths

Baseline: `dev = 7358160e808fb1870eeb20f5da8df832667019d1` (2026-11-21).
Android paths are relative to the module root shown. iOS file names come from `docs/parity/*` at the same SHA; they are **descriptions of an October 2026 iOS app**, not recovered source.

Legend for **Evidence**: `[A]` current Android code/tests · `[P]` parity rows · `[D]` porting dossier (`docs/port`, unrelated branches) · `[V]` visual capture · `[U]` uncertain.

---

## 1. Launch

- **iOS** `[P][D]`: `OpenCode/App/OpenCodeApp.swift` (`@main`, one process-lifetime store, ends leftover Live Activities), `LaunchBloom.swift` (blank cover while the restored session row resolves), `SceneWindows.swift`, `WindowRoster.swift`.
- **Android** `[A]`: `app/src/main/kotlin/ai/opencode/app/OpenCodeApplication.kt` (installs `AppContext`, `EventBatcherHooks`, `AppPhases`, `ActiveScene`, `DevTools`, `AppDependencies`, `SceneWindows`, ends orphaned Live Updates, recovers call logs) → `MainActivity.kt` (retained root store, splash/`LaunchBloom`, permission launchers, back-keeps-call, `AppView`) .
- **State/actions**: `AppFeature` in `app/AppFeature.kt`; `LaunchBloom` holds a blank cover until the restore decision; `Connection { Idle, Pairing, Connecting, LoadingHome, Connected, Failed, Picking }`.
- **Persistence**: `app-left-at`, `install-history`, theme keys; transcripts read from `filesDir/support/transcript-snapshots.json`.
- **Failure states**: launch never blocks on network; a failed restore shows the connection screen with `FailureContext`.
- **Rebuild note**: iOS must end Live Activities on launch and decide cold-launch routing from the last-viewed session key.

## 2. Pairing and manual servers

- **iOS** `[P][V]`: `App/AppFeature+Pairing.swift`, `+Servers.swift`, `+ServerFlow.swift`, `AppView.swift`; `Settings/PairingScanner.swift` + `CameraScanner` (AVFoundation QR).
- **Android** `[A]`: `app/AppFeaturePairing.kt` (`PairingArrival { firstComputer, newComputer, knownComputer }`, `validatePairing`, `requestPairing`, `landPairing`), `AppFeatureServers.kt`, `AppFeatureServerFlow.kt`, `AppView.kt` (`SetupSteps`, `SavedServerList`, `ServerFormSheet`, `PairingScannerPresenter`); scanner in `feature/settings/servers/PairingScanner.kt`, `QRCameraPreview.kt`, `ServerCameraClient.kt`; link parsing in `server/OpenCodePairingLink.kt`.
- **Wire**: `GET /auth/connect/{code}` per origin (no auth, 5 s) → token; then `GET /api/info`.
- **Persistence**: `saved-server`, `saved-servers` (Keychain), `install-history`.
- **Copy** `[V]`: "Scan Pairing Code", "Enter a Server Manually", "Server address", "Connect", "Copy Error Report"; three setup steps with `opencode pair`.
- **Failure states**: invalid/expired code, 404 (no pairing support), unusable address, all-loopback refusal, unreachable host — each with preserved copy in `PROTOCOL.md` §2.
- **Rebuild note**: camera QR needs a live device; the simulator cannot scan. Use `DataScannerViewController` or AVFoundation; both are UIKit bridges with precedent in the original app.

## 3. Persistence and reconnect

- **iOS** `[P][D]`: `OpenCodeClient+Connection.swift`, `NetworkRetry.swift`, `NetworkPath.swift`, `ServerLink.swift`, `SharedKeys.swift`, `Keychain.swift`, `TranscriptCachePersistence`.
- **Android** `[A]`: `server/ServerLink.kt` (`ServerLinkClient` Key: address race, 3.5 s probe, 2 failures, reroute/foreground/retry/timeout resets), `server/retry/NetworkRetry.kt` (policies `request`, `send`, `once`, `stream`, `streamOverflow`, `sessionWait`), `server/retry/NetworkPath.kt`, `server/OpenCodeTransport.kt` (pools: request, measured, long-poll, event stream, media), `drawer/HomeConnectionFeature.kt` (SSE lifecycle, grace, offline).
- **Persistence keys**: `saved-server(s)` keychain; `cachedHomeSnapshot`; `transcript-snapshots.json` (4 MB / 16 entries / 14 days); `session-read-dates.json`; `last-viewed-sessions.json`; `followed-sessions.json` (pins); `manually-unread-sessions.json`; `muted-sessions.json`; `hidden-sessions.json`; `session-agents.json`; `primary-agents.json`; `model-variants.json`; `recent-models.json`; `model-visibility.json`.
- **Cancellation** `[A]`: `CancelID { Health, Home, Notification, SystemActions, SystemSession, SwitchTimeout }` in `AppFeature`; `{ Events, Refresh, ActiveAncestry, Attention, Prefetch, SelectedTranscript, DeletionError, NetworkPath, ConnectionGrace, … }` in `HomeFeature`.
- **Failure states**: 401 stops reconnect entirely; transport failure → "Couldn’t reach the OpenCode server"; stall → reconnecting; two losses → disconnected; first backup address raced.
- **Rebuild note**: SSE needs a 90 s read timeout reset by heartbeats, not a request timeout.

## 4. Home, drawer and projects

- **iOS** `[P][D][V]`: `HomeFeature.swift` (1,381), `HomeView.swift` (914) with `sessionDrawer`, `CatchUpChrome`, `DrawerMetrics`, `PinnedRowInteraction`, `ActivityRing`, `AgentActivityGlyph`; `SessionDrawerContainer.swift`; `CatchUpStack.swift`.
- **Android** `[A]`: `feature/drawer/.../HomeFeature.kt` + 16 `HomeFeature*.kt`; `HomeView.kt`, `HomeViewDrawer.kt`, `HomeViewState.kt`; `list/DrawerList*.kt`, `DrawerPinDrag`, `DrawerPinMove`, `DrawerSelection`, `DrawerRowInteraction`, `DrawerLiftedRow`, `ArchivedPage`, `InboxSidebarList`; `container/SessionDrawerContainer.kt`, `SessionDrawerController.kt`; `CatchUpFeature` + `CatchUpStackController`; `switcher/ServerSwitcher`.
- **State**: `projects`, `sessions`, `activeSessionIDs`, `parents`, pins/unread/muted/hidden mirrors, `catchUpState`, `sessionPages`, `subagentStack`, `attention`, `unsentDrafts`, `deletion`.
- **Wire**: `GET /api/project`, `GET /api/session?parentID=null&archived=false&order=desc&limit=50`, `GET /api/session/active`, `GET /api/session?search=`, `GET /api/session?cursor=`, `GET /api/session?archived=true`, `POST /api/session/{id}/view`.
- **Events**: `session.created|renamed|deleted|archived|unarchived|moved|viewed|forked`, `session.execution.*`, `permission.asked`, `form.create*`.
- **Cancellation**: see §3 plus `DeleteSession(id)`, `ViewReceipt(id)`, `CachedTranscript(id)`, `SessionSearch`, `OlderSessions`, `LinkedSessionOpen`.
- **Errors**: `DrawerFailureNotice`, deletion two-phase with backup and restore, `ArchivedPage` archive/unarchive errors.
- **Visual contract** `[V]`: title "Sessions", Search, "Catch Up" with count, "What's New" with dot, Pinned/Recents sections, per-row status dots, "New Session" pill, gear button.
- **Android-only**: new-session-after-30-minutes-away (`HomeFeature+NewSessionAfterAway`), archived sessions page, selection mode instead of swipe actions — **do not inherit**.

## 5. Sessions and subagents

- **iOS** `[P][D]`: `SessionFeature.swift` (3,027; `RefreshReason`, `Delegate`, 95 action cases), `SessionView.swift` (2,394; `SessionView`, `SessionTranscriptView`, `SessionHeaderBackdrop`, `ComposerLayout`, `WorkingIndicator`, `SessionContextRing`, `AttachmentMenuOverlay`), `SessionSheetFeature/View`, `ShellOutputFeature/View`, `PassesDragsToTranscript.swift`.
- **Android** `[A]`: `feature/session/.../SessionFeature.kt` + ~40 `SessionFeature*.kt`; `SessionPageStack.kt`; `SessionSheetFeature.kt`; `ShellOutputFeature.kt`; `BackgroundWorkPanel.kt`; `AgentActivitySource.kt` / `agentactivity/*` (orb + shaders).
- **Reducer order** (`coreSteps`): call/bindings → stream → pending inputs → sending → dictation → run lifecycle → models/family → browser/background work → jobs → attachments → requests → history. Composition then nests ShellOutput, SessionSheet, FolderBrowser, Voice, and scopes Browser, Dictation, RequestDock, ComposerAttachments.
- **Cancellation** (full list): `UniversalLink, Models, Requests, Inbox, InboxFetch, PromptEcho, RequestsRetry, RequestsChanged, Freshness, Watchdog, EarlierHistory, FamilyRefresh, Shells, Jobs, Revert, MissingFolderMove, Interrupt(gen), InterruptSettle(gen), RunEndCheck(gen), StrandedSteer(gen), BackgroundHint, MoveToBackground, ViewReceipt, ResyncDelay, ResyncMinimum, VoiceExit, VoiceViewing, Autocomplete{Catalog,Commands,Files,Sessions,AutoRun,Command,CommandWait}, Agents, WindowReset`.
- **Critical semantics**: `Freshness` is not `cancelInFlight` (one in-flight read, newest `requestID` wins); visible limit starts 20 with a settled window 45/120 and a 2 s reset; `initialFetchLimit=30`, first frame 12.
- **Subagents**: `subagentStack` in Home, `SessionPageStack` presentation, family BFS in `server/live/LiveFamily.kt` (≤6 in flight, 100-session cap), `SessionFeatureSubagents` tests.
- **Errors**: run error row (`RunErrorRow`), failed sends/outbox, "Run failed: {type} — {human}", stranded steer recovery.

## 6. Transcript rendering

- **iOS** `[P][D]`: `TranscriptEntry.swift`, `TranscriptListView.swift`, `TranscriptListViewController.swift` (1,591, UIKit follower), `TranscriptEntryView.swift` (885; `TranscriptMetrics`, mosaic, gallery), `TranscriptUserMessage.swift`, `MarkdownBlockView.swift`, `HorizontalOverflowFade.swift`, `TranscriptScrollBehavior.swift`.
- **Android** `[A]`: `feature/transcript/.../` — `TranscriptEntry.kt`, `TranscriptContract.kt`, `list/TranscriptList.kt` (bottom-anchored `LazyColumn`), `TranscriptListScroller.kt`, `TranscriptListSnapshot.kt`, `NewMessagesMark.kt`, `markdown/*` (`OpenCodeMarkdownBlock.kt`, `InlineMarkdownParser`, `MarkdownStream.kt`, `MarkdownTailHeal`, `MathSyntax`, `SwiftText`, `SessionLinks`), `markdown/ui/*` (`MarkdownBlocksView`, `MarkdownTable`, `MarkdownImage`, `CodeCopyButton`, `ArrivingText`, `TranscriptTextReveal`), `rows/*` (`InlineRows`, `ToolRows`, `ToolImages`, `RunErrorRow`, `ReplyActions`, `TranscriptRowSlots`), `user/*`, `links/*`, `selection/*`.
- **Metrics** `[A]` (`MediaFoundation.kt`): compact 4, clustered 8, bubbleVertical 10, standard 12, gutter 16, turn 20, bubble radius 10, card 8, control 6, max bubble 0.82, readable 720 dp, 48 dp hit target.
- **Markdown**: parsed once per part into blocks with an inline cache; streaming commits at unit boundaries and heals the tail; tables, task lists, code bands, math (jLaTeXMath), Mermaid (WebView), link previews, session chips, quote selection.
- **Errors**: failed image → placeholder; markdown image outside the session folder waits for a tap; unsupported media → unavailable placeholder.
- **Rebuild note**: this is where iOS and Android diverge most. Recovered iOS used a UIKit collection view with a custom follower; **do not port Android's LazyColumn motion as if it were iOS**, and do not claim the original feel. Reserve the motion decision for an explicit native design step.

## 7. Composer and pending inputs

- **iOS** `[P][D]`: `SessionView.swift` composer sections, `ComposerTextInput.swift` (277; `ImagePasteTextView`), `ComposerSendTransition.swift`, `AttachmentMenu.swift` (650), `AttachmentPicker.swift`, `Autocomplete*` (6 files), `SessionView+PhotoSheet.swift` (n/a).
- **Android** `[A]`: `feature/composer/...` — `ComposerTextInput.kt`, `ComposerFieldLink.kt`, `ComposerDoubleTap`, `ComposerKeyboardMorph`, `AutocompleteFeature.kt` + `AutocompleteViews.kt`, `ComposerAttachmentsFeature.kt`, `AttachmentPicker.kt`, `AttachmentMenu.kt`, `RequestDockFeature.kt`, `RequestDockView.kt`, `QueuedMessagesSheet.kt`, `PromptOutbox.kt`, `ComposerPersistence*.kt`, `modelpicker/OnePicker*`.
- **Pending inputs / steering**: `GET|PATCH|DELETE /api/session/{id}/inbox[/{inputID}]` with `delivery: steer|queue`; `QueuedMessagesSheet`; delivery change events.
- **Persistence**: `composer-state.json` (500 ms debounce, 30-day eviction), `ComposerAttachments/`, `model-display-names.json`.
- **Cancellation**: `CancelID { Requests, Models, Send }`, `{ Location, Upload(id) }`.
- **Errors**: failed send keeps the draft and offers retry; `SentImageFlight` n/a; uploads unsupported copy.
- **Visual contract** `[V]`: composer pill corner 28, `+`/`×`, "Message", mic; steer long-press (0.9–1.1 s) opens Steer/Queue; attachment menu is a panel with Camera/Photos/Files plus the system Paste capsule.

## 8. Forms, permissions and request review

- **iOS** `[P][D][V]`: `RequestReviewView.swift` (366), `FormModels.swift`, `SessionView` request dock, `RequestPanelFitTests`.
- **Android** `[A]`: `feature/composer/.../RequestReviewView.kt`, `RequestDockFeature.kt`, `RequestAnswer.kt`, `RequestCollapse.kt`, `PermissionPanelParts.kt`; `server/model/PendingRequests.kt`, `Forms.kt`; `SessionFeatureRequests.kt`.
- **Wire**: `GET /api/permission/request`, `GET /api/form` (60 s), `POST /api/session/{id}/permission/{requestID}/reply {decision}`, `POST|DELETE /api/session/{id}/form/{formID}`.
- **Rules**: strict decode; `default` key maps to `defaultValue`; progressive visibility clears hidden answers; external fields must be true; `global` forms attach to the open session and don't light the drawer; a failed read is a failed snapshot.
- **Errors**: `request-load-error` banner, submit failure keeps the answer, expired request, malformed form, many options.
- **Copy** `[V]`: "Run Command?", Deny / Always Allow / Allow Once, "Use native controls" for questions, "1 pending request … Review", "Needs your input".

## 9. Attachments, media and browser

- **iOS** `[P][D]`: `AttachmentCameraView/Lenses.swift` (899/234), `ComposerImageImport`, `AgentFiles/*` (`AgentFileLoader`, `AgentFileViewer`, `AgentFileReference`), `Browser/BrowserView.swift`, `BrowserFeature`, `LinkMenu`, `MediaPresentation`, `FullscreenViewer`, `ZoomableImagePage`, `Mermaid/*`, `SyntaxHighlighter`.
- **Android** `[A]`: `feature/media/.../` — `MediaFoundation.kt` (`DecodedImageCache` budget), `MediaReferenceClient.kt`, `MediaPresentation.kt` (viewer + drag dismiss + predictive back), `FullscreenViewer.kt`, `agentfiles/*` (loader, cache, previews, gallery, bento, code view), `browser/*` (`BrowserFeature`, `BrowserWebViews` with WebView pool and obscured insets, `BrowserLinkPolicy`, `LinkMenu`), `linkpreviews/*`, `mermaid/*`.
- **Wire**: `GET /api/experimental/media/{hash}`, `GET /api/fs/read/{rel}`, `POST /api/experimental/fs/write`, `GET /api/fs/find`, `GET /api/fs/list`.
- **Limits**: tool images 16 / 20 MB each / 32 MB total; syntax highlighter 128 KB / 1,000-byte lines; preview byte caps.
- **Errors**: unavailable placeholders, failed preview → plain link, drawing hand-off failure.
- **Rebuild note**: WebKit is permitted for the audited browser and rich content behind a limited interface; do not use it as the shell.

## 10. Voice and dictation

- **iOS** `[P][D]`: `Voice/VoiceFeature.swift` (772), `VoiceView.swift` (695; `VoiceCallComposer`, dictation bar, `DotScopeView`), `VoiceCallClient.swift` (1,808; `VoiceCallCoordinator`, `LiveCallCoordinator`), `VoiceAudioClient.swift` (1,029), `LiveProtocol/LiveClient` (GPT-Live), `RealtimeProtocol/RealtimeClient`, `VoiceTurnTaking.swift`, `VoiceWorkClient`, `VoiceTranscript.swift` (`VoiceHandoff`), `VoiceCallActivity` (Live Activity), `RaiseToEar` detector, `DictationClient` (on-device).
- **Android** `[A]`: `feature/voice/...` — `VoiceFeature.kt` (1,621), coordinators, `LiveProtocol` (engines `gptLive`, `realtime`, `grok`), WebRTC clients, `AudioSessionOwner`, `VoiceAudioEngine`, `VoiceQuietGate`, `VoiceUplinkWatch`, `RaiseToEar`, `FloatingCall*`/`LivingOrb*`, `DotScope*`, `WispOrb*`, `VoiceCallLog*`, `VoiceDelegator` + `VoiceSessionDelegator`, `VoiceWorkClient`, `ServerVoiceClient` (`POST /api/experimental/voice/session`, `GET /api/experimental/voice/models`).
- **Gating**: Voice Mode `voice-mode-enabled` default **false**; Raise to Talk default false; live-call surfaces Experimental.
- **Persistence**: `voice-engine`, `voice-call-voice`, `voice-transcripts.json`, `voice-models-by-server`, `server-voice-provider`, keychain OpenAI/xAI keys.
- **Cancellation**: `Call, Goodbye, Instructions, ScreenInstructions, Reconnecting, ReplyActiveRefresh, WorkAdmission(callID), WorkCall(callID), ReplyWatch(promptID), ReplyStepProbe(promptID), ReplyDeferral(key), CallScope, CallCommands, PresenceLinger`.
- **Unverified**: real-device echo/latency, held-result rule, WebRTC offers without host candidates.
- **Rebuild note**: WebRTC spike proved an app-owned 24 kHz audio path over libwebrtc; for iOS the historical client already used WebRTC. Treat voice as Experimental and off.

## 11. Settings and experiments

- **iOS** `[P][D][V]`: `SettingsView.swift` (234; `SessionSettingsView`, `AdvancedSettingsView`), `DiagnosticsView.swift`, `ExperimentalSettingsView`, 183 What's New entries, `Onboarding/*`.
- **Android** `[A]`: `feature/settings/.../SettingsFeature.kt` (`SettingsPage` enum), `HomeSettingsFeature.kt`, `SettingsView.kt` (Nav3), `connection/*`, `servers/*`, `serverdetails/*`, `onboarding/*`, `whatsnew/*`.
- **Experiments** (all **off** by default): `hide-models`, `background-call-intent`, `voice-session-delegator`, `share-screen-with-agents`, `inbox-sidebar`, `session-live-activity`, `sound-effects`, `server-address-links`, `in-app-browser`, `welcome-preview`; retired `since-you-left`, `session-switcher`, `server-title-switch`.
- **Visual contract** `[V]`: Settings sheet with Done, connected card (green dot field, address, Change), rows Notifications / Voice / Diagnostics with tinted icon tiles, separate What's New row.
- **Android-only**: Language row; Developer/Playgrounds.
- **Rebuild note**: keep every new feature behind an off-by-default switch, as both platforms do.

## 12. Notifications, share handoff, Live Activities

- **Notifications** `[P][A]`: `server` has no push relay (APNs-only plugin); Android implements FCM behind `SessionNotificationsClient` + AES-GCM `NotificationCrypto` + key store, permission gate, icon badge ledger. **iOS: Experimental, off; requires a relay and credentials.** Copy: "Needs your input", Done/Failed.
- **Share handoff** `[P][A]`: iOS `OpenCodeShare/` extension + App Group `share-targets.json` + `Shares/{uuid}/share.json`; Android `feature/system/share/*` (`ShareActivity`, `ShareModel`, `ShareSender` direct REST, `ShareHandoff`, `ShareInbox`, `ShareCredentialStore`). Wire: `POST /api/session`, `POST /api/session/{id}/prompt`, `POST /api/experimental/fs/write`.
- **Live Activities** `[P][A]`: iOS `VoiceCallActivity` + WidgetKit extension; Android `liveactivity/*` (session run, voice call, dictation) with `LiveUpdateTracker`. Wire: none (phone-local).
- **Intents/App Intents** `[P][A]`: iOS `System/Intents/*` + widget extension; Android App Actions, tiles, shortcuts, AppSearch — **Android-only, exclude**.

## 13. The recovered UI contract (from the capture harness)

`scripts/ios-reference/CaptureUITests/CaptureTests.swift` (486 lines, unreachable from `dev`; on the four unrelated branches) drives the installed app by bundle id `ai.opencode.mobilecode`. It is the only first-hand record of identifiers and copy.

**Accessibility identifiers:** `transcript-list` (collection view), `drawer-session-row-<sessionID>`, `drawer-catch-up`, `drawer-whats-new`, `catch-up-done`, `whats-new-list`, `pending-attachment-0`, `subagent-task`, `tool-image-mosaic`, `session-menu`, `session-title`, `session-sheet`, `background-activity`, `background-work-panel`, `background-shell-<shellID>`, `shell-output`, `request-review-close`, `request-load-error`.

**Labels used as selectors:** "Scan Pairing Code", "Enter a Server Manually", "Server address", "Connect", "Copy Error Report", "Search sessions", "New Session", "Project", "Message", "Add attachment", "Photos"/"Paste"/"Camera", "Choose model", "Used 1 Shell", "Used 1 Subagent", "Steer message", "Steer"/"Queue", "Allow Once", "Use native controls", "Session Info", "Settings", "Diagnostics", "Review requests"/"Review", "Pin"/"Unpin", "Working", "Open sessions"; nav titles "Model", "Settings", "Diagnostics".

**Lab launch protocol:** args `-AppleLanguages (en)`, `-AppleLocale en_US`, `-lab-interface-style light|dark`, `-lab-pasteboard-image`; env `OPENCODE_PASSWORD`, `OPENCODE_LAB_SERVER_URL`, `OPENCODE_LAB_LAST_SESSION_ID`, `OPENCODE_LAB_WHATS_NEW=unseen`, `OPENCODE_LAB_DISABLE_TRANSCRIPT_DISK_CACHE=1`.

**Consequences for the rebuild:** these identifiers and strings are the closest thing to an original contract; reuse them as accessibility identifiers where they still describe the UI. They also prove the original app had a drawer, a sheet-based session menu, a background-work panel keyed by shell id, a transcript collection view, and a "review requests" concept — all consistent with the parity rows.

## 14. Deliberate differences to keep separate from dev parity

| Behaviour | Android (current dev) | Recovered iOS | Decision owner |
| --- | --- | --- | --- |
| Transcript motion | LazyColumn, row arrival only | UIKit follower, send flights, row growth | native design step |
| Photo picking | system picker | in-app photo sheet + flight | native design step |
| Autocomplete | list, next-frame filtering | spring simulation + chip flight | native design step |
| Quotes | quote cards | Markdown blockquote | adopt Android? (product) |
| Failed send | unsent session row | failed message into next draft | native design step |
| Fonts | Inter + OpenMono (desktop) | SF + SF Mono, Berkeley Mono onboarding | **explicit decision required** |
| Glass | flat fills + hairlines | Liquid Glass (iOS 26) | use current SwiftUI glass for controls |
| Notifications | FCM + relay missing | APNs relay package | Experimental, off |
| Assistant | side-button hold (branch, reverted) | none recovered | exclude |
