# IOS_GAPS — what the Android port dropped, deferred or could not express

Purpose: when rebuilding the iPhone app, the Android app is the behavioural baseline **except** where Android deliberately omitted something the original iOS app had. Those omissions are the risk surface for the rebuild. Each entry names the evidence and whether it is reconstructable.

Status vocabulary:
- **REBUILD** — iOS-only behaviour that the new app should have; evidence is a description, not source.
- **ADAPT** — iOS behaviour that must be re-decided for current Apple APIs.
- **KEEP-ANDROID** — Android chose differently; iOS should not inherit it.
- **UNVERIFIED** — evidence exists but cannot be checked without the original app or hardware.

Sources: `docs/parity/*.md` at `dev = 7358160e` (synced to iOS `01eef583`), `docs/port/deviations.md` + `parity-review.md` on `webrtc-spike` (iOS `16b40f7`), `docs/port/voice-ios-issues.md` (iOS `998cb16`).

---

## 1. iOS-only behaviour the port marks n/a (≈100 files)

### 1.1 Transcript motion stack — **REBUILD, high risk**
`docs/parity/transcript.md` rows 12, 30, 41, 46, 47, 53, 55, 56, 58, 59, 62, 66, 68, 70, 72, 75, 76, 77, 78, 79 are all `n/a` on Android. Evidence describes: a UIKit `UICollectionView` with a `BottomSpring` follower (`jumpOmega 14`, `arrivalOmega 20`, `arrivalSpeed 1080 pt/s`, `arrivalReach 2.5` screen heights, settle `|x|<0.5 && |v|<20`), `SendFlight` (omega 14, 0.8 s timeout), `RowEntrance` (0.25 s, 6 pt rise, max 4 rows, 0.5 s window), scroll springs, mark hand-off, promotion morphs, and a single `CADisplayLink`.

The Android app replaced all of it with a standard bottom-anchored `LazyColumn` and says so in `AGENTS.md`. **The new app must decide this from scratch**: the recovered numbers are evidence of intended feel but not a specification, and the migration instruction forbids claiming pixel parity.

### 1.2 In-app photo sheet + photo library — **ADAPT**
`composer.md` rows 34, 39, 44, 45, 65, 75–84, 94, 118, 143, 148, 153–156, 158; `session.md` 68. iOS had an in-app photo sheet with a morphing `+` menu, photo flight, recent-photo peek, picker tunables and a photo library client; Android dropped it for the system photo picker (Play policy) and keeps only `VideoDurationBadge`/`formatVideoDuration`. On iOS the equivalent decision is `PhotosPicker` vs a custom sheet — an explicit native decision, not a port.

### 1.3 Autocomplete simulation and chip flight — **ADAPT**
`composer.md` rows 23–28 (`AutocompleteMotionController`, `AutocompleteParameters`, `AutocompleteSimulation(+Frame)`, `AutocompleteSpring`, `AutocompleteTouchTracker`) plus their tests. Android uses a `LazyColumn` with panel roles and filters on the next frame. iOS used a spring simulation with a chip flight. Decide: SwiftUI-native list (recommended) and record the departure.

### 1.4 UIKit list/container mechanics — **REBUILD**
`core.md` 40, 49, 58; `transcript.md` 41/47/56; `drawer.md` 20/26/34; `composer.md` 81; `session.md` request-panel and header rows. Includes `TouchRecovery` (14 tests, all n/a), `ScrollsToTop`, `MadeOnce`, `DrawerLiftedRow` (partial), drag audits and follow traces. These exist because SwiftUI/UIKit had specific defects; with a new UI layer they may or may not recur.

### 1.5 iOS diagnostics and lab tooling — **EXCLUDE unless re-justified**
`devtools.md` 9–11, 17, 19–21, 24–26, 29, 31, 34–35, 37–40, 43–53, 60: Motion X-Ray, Motion Watch, Touch Probe, Scrawl, MetricKit, Team Feedback, Tuning remote page, eleven playground fixtures. Android replaced them with Perfetto, Perf HUD, Session Lab checkpoints and on-phone tuning. Keep the *diagnostics journal* behaviour (`DiagnosticsRecorder`, `ProblemReport`) and drop the instrument-specific tooling unless a concrete need appears.

### 1.6 Glass and variable blur — **ADAPT**
`core-ui.md` 115 (`Glass.swift`), `RenderServerLoop` row 123, `composer.md` 81, `session.md` 52, `voice.md` 17. iOS 26/27 Liquid Glass and the private `CAFilter` `variableBlur` were deliberately not carried to Android (App Store risk noted in the dossier). Current iOS: use `glassEffect`/`GlassEffectContainer` where genuinely a control surface, and a gradient fade instead of the private filter.

---

## 2. Rows marked `partial` on Android (behaviour exists but differs)

| iOS file | Android state | Rebuild implication |
| --- | --- | --- |
| `OpenCodeClient+Transcript.swift` | Markdown parsed **in composition** with an LRU of 16 parts, not at decode | Parse once off the main actor, keyed by part id + text; cache bounded and invalidated on memory warning |
| `OpenCodeTranscriptItem.swift` | Markdown carried as text | Carry parsed blocks |
| `DictationViews.swift` | `dictationLevels` override waits on the Welcome story | Decide whether the level meter override is needed |
| `SessionView+PhotoSheet.swift` | only `+` menu state | see 1.2 |
| `AttachmentMenu.swift` / `AttachmentPicker.swift` | Material `DropdownMenu`, no hold/slide/selection ticks | iOS gesture contract is described but unmeasured |
| `ComposerSendTransition.swift` | only the field's touch ownership | send flight is 1.1 |
| `DrawerLiftedRow.swift` | row stays in the list; no window-level x-follow | n/a for a SwiftUI drawer unless the hold-drag is rebuilt |
| `HomeFeature+Sessions.swift` | report-a-problem delegate does nothing | Developer Mode trace upload existed on iOS |
| `BrowserView.swift` | page fixed/sticky elements not kept clear of bars (Chromium has no obscured-inset API) | WebKit has `obscuredContentInsets` — an iOS advantage to use |
| `SessionNotifications.swift` | Android side complete but fails open; needs APNs relay | Push needs the relay; keep off by default |

---

## 3. Deferred on iOS itself at the port baseline (so also incomplete evidence)

- **Push notifications**: iOS `SessionNotifications.swift` deferred; `packages/notify-relay` (APNs) exists but is out of the app target. Four iOS commits (`d0ed2a9`, `6eff60f`, `f2afbb8`, `d4cd513`) are recorded as *skipped* by the port.
- **Voice** was deferred, then re-adopted mid-port (`decisions.tsv` rows 43 and 72). At `16b40f7` the port still listed voice surfaces as `partial`.
- `GlassMorphTrace.swift` deferred as lab-only.

## 4. Android-only features that must **not** be treated as iOS requirements

`docs/parity/app.md` 33–45 (`MainActivity` dispatch, `keepCallOnBack`, deep-link intents, locale filter, `supportsRtl=false`), `core-ui.md` 44–57 (Android-only components), `settings.md` 248 (Language row), `drawer.md` 48/66/67 (new-session-after-away, archived page, selection mode), `voice.md` 11/42/57/71 (foreground service, PixelCopy screenshot, call persistence, route graduations), `system.md` 9–16/23/39/47 (App Actions, Quick Settings tiles, Glance widgets, AppSearch, launcher shortcuts, Live Updates), `server.md` (archived sessions, job APIs, quoted comments, preferred URLs).

These are **KEEP-ANDROID**; the iOS app obtains the equivalent from Apple APIs if it needs it (WidgetKit, App Intents, ActivityKit, UINotificationServiceExtension) — each an explicit decision.

## 5. Deliberate behaviour drops (verify before re-adding)

- Markdown blockquote quotes → Android quote cards (`session.md` 31/101).
- Failed-message-in-next-draft → Android "unsent session" row (`composer.md` 98).
- iOS "requiresConnection" network category and constrained-network refusal (`server.md` 37/125).
- iOS `BadgeAuthorization` (`system.md` 23).
- iOS protected-data / locked-device tests (`transcript.md` 141, `composer.md` 128).
- App Group / keychain-group sharing (`core.md` 28, `system.md` 27/38) — iOS needs its own App Group for share + widgets.

## 6. Tests the port deleted, named individually in the parity corpus

The parity README's audit is mechanical: every iOS test is either ported or deleted with a reason. Deleted test *names* are the best surviving index of iOS-only behaviour. High-value clusters for a rebuild:

- `TranscriptScrollBehaviorTests` (all 51 dropped), `TranscriptRowGrowthTests`, `TranscriptGestureReleaseTests`, `TranscriptTailInsertTests`, `BottomChromeTests`, `PromotionMorphTests`, `NewMessagesListTests` (23 of 24 dropped) — the motion stack.
- `PhotoFlightTests`, `PhotoFlightTests+Reservations`, `PhotoLibraryAccessTests`, `PhotoSheetInteractionTests`, `PhotoPillViewTests`, `PhotoSheetRenderTests`, `SentImageFlightTests` — the photo sheet.
- `PlusMenuTouchLifetimeTests` (12), `AttachmentMenuPressTests`, `SlowMotionTests` — the hold/slide menu.
- `TouchRecoveryTests` (14), `RequestPanelFitTests`, `SessionHeaderStyleTests` variable-blur cases — UIKit plumbing.
- `DrawerDragAuditTests`, `DrawerDragDiagnosticsTests`, `DrawerPerfGateTests`, `DirectionalPanGestureRecognizerTests` (partial) — drawer drag.
- `VoiceLiveTests` (8), `LiveRTCPlayoutClockTests` (3), `IdleVoiceSensorsTests`, `FloatingCallStageTests`, `DotScopeSimulationTests` Metal cases — voice.
- `AppIconBadgeTests`, `MultipleWindowsTests`, `LaunchBloomTests`, `AppFeatureTests+Migrations` — launch/badges/windows.

Full per-file detail: `docs/parity/*.md` "Tests" sections at `7358160e` (≈2,858 ported / 268 deleted at the date of the README audit — **a historical count, not current**).

## 7. Contradictions preserved

1. `settings.md:237` says new-session-after-away is `todo`, while `drawer.md:48` says the behaviour is ported. The `todo` refers to the What's New entry.
2. `drawer.md:89` says 553 tests, `:162` says 554.
3. README's JVM test column is frozen at iOS `fc25a553`; module totals are later.
4. `app.md:37` contains a corrupted sentence (editing accident).
5. `docs/port/decisions.tsv` marks voice "deferred" (row 43) and later "in scope" (row 72); `sync.json` still lists voice files as deferred.

## 8. Unverified / blocked

- Any claim about what the original app *looked* like on device: captures are simulator-only, glass under-renders, and the capture script pins scroll into coarse bands.
- Voice call behaviour on real hardware (echo, uplink stalls, held-result rule) — the dossier says explicitly untested against `gpt-live-1`.
- WebRTC host-candidate-less offers against the real service.
- Push notification delivery (no relay credentials in this environment).
- QR pairing on device (no camera in simulator).
