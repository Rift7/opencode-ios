# iOS migration — parity map

Status vocabulary: `not started`, `scaffold`, `partial`, `done`. A row is `done` only when the behaviour exists,
is tested, and the test passes. Every claim names a source path; commit SHAs distinguish current `dev` behaviour
from historical iOS evidence.

Scaffold scope: the app boots into an explicit disconnected, loading or failed state; no server is contacted and
no session screen exists yet. `done` means the behaviour exists and its test passes in this repository.

Baselines:

- Behaviour: `dev = 7358160e808fb1870eeb20f5da8df832667019d1`.
- iOS evidence: parity corpus synced at iOS `01eef583`; screenshots at `d809b1e` and `16b40f7` (October).
- New code: `ios` branch from the same `dev` SHA.

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
| Reducer/store semantics | `core/.../store/{Reducer,Effect,Store,TestStore}.kt` | TCA | `ComposableArchitecture` 1.26.2 (exact) | done |
| Dependency clients | `core/.../dependencies/DependencyValues.kt` | `Core/Dependencies` | `ios/OpenCodeKit/Sources/OpenCodeCore/Dependencies` (probe, date, id) | scaffold |
| Shared keys and storage | `core/.../sharing/{Shared,SharedKeys}.kt` | `Core/SharedKeys.swift`, `Keychain.swift` | `ios/OpenCodeKit/Sources/OpenCodeCore/Storage` | scaffold |
| Keychain | `core/.../sharing/LiveSharedBytes.kt` | `Core/Keychain.swift` | not started (owner-supplied service) | not started |
| Semantic colour tokens | `core/.../ui/{BrandPalette,OpenCodeColors}.kt` | `Core/Theme/Theme.swift` (system colours) | `.../Design/OpenCodeColorTokens.swift` | done |
| Type tokens | `core/.../ui/OpenCodeTypography.kt` | system text styles | `.../Design/OpenCodeTypeTokens.swift` | done |
| Logging and redaction | `core/.../log/AppLog.kt` | `Core/AppLog.swift` | `.../Logging/AppLog.swift` | scaffold |
| Test isolation and network guard | (test-only `TestNetworkBlock`) | `TestIsolationGuard` | `.../OpenCodeTestSupport` | done |
| Haptics vocabulary | `core/.../haptics/HapticsClient.kt` | `Core/HapticsClient.swift` | `.../Haptics/` | not started |

## Server

| Behaviour | Android source | Recovered iOS source | New path | Status |
| --- | --- | --- | --- | --- |
| Transport, pools, security | `server/OpenCodeTransport.kt`, `TransportSecurity.kt` | `OpenCodeClient+Transport.swift` | `ios/OpenCodeKit/Sources/OpenCodeServer` | not started |
| Retry and backoff | `server/retry/NetworkRetry.kt` | `NetworkRetry.swift` | same | not started |
| Wire models | `server/model/*.kt` | `OpenCodeClient+Payloads.swift` | same | not started |
| SSE decode and batching | `server/live/LiveEvents.kt`, `EventBatcher.kt` | `OpenCodeClient+Events.swift` | same | not started |
| Pairing redeem | `server/OpenCodePairingLink.kt` | `OpenCodePairingLink.swift` | same | not started |
| Family BFS | `server/live/LiveFamily.kt` | `OpenCodeClient+Family.swift` | same | not started |

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
| Transcript motion | bottom-anchored `LazyColumn`, no follower | pending native decision (D-6 in the audit plan) |
| Photo picking | system picker | system picker proposed; no in-app photo sheet |
| Autocomplete | list, next-frame filtering | SwiftUI-native list |
| Quotes | quote cards | pending product decision |
| Notifications | FCM, relay absent | Experimental, off until a relay exists |

## Test coverage

| Area | Tests | Status |
| --- | --- | --- |
| Design tokens | `OpenCodeKit/Tests/OpenCodeCoreTests/DesignTokenTests.swift` | scaffold |
| Log redaction | `.../LogRedactionTests.swift` | scaffold |
| Keychain and shared keys | `.../StorageTests.swift` | scaffold |
| Store semantics | `.../StoreSemanticsTests.swift` | scaffold |
| Server | none yet | not started |
| UI (XCUITest) | none yet | not started |
