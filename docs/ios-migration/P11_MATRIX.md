# P11 acceptance matrix — settings, experiments, diagnostics, onboarding, catalogue, headers, pairing, models, autocomplete and files

Baseline for this phase: `origin/ios` at `0ec10ba4` (PR #9 squash merge, tree
`02dad71ef45e77a01640c9cc7115d4c5d12dc1fb` equal to the reviewed P10 tree `9880eeb9`).
Android behaviour baseline: `origin/dev` at `7358160e` (2026-11-21).

## Freshness

The audited sources below last changed before the behaviour baseline, so current `dev` is the
source used here. Their last commits are recorded for the audit trail, not because another branch
was adopted.

| Area | Source | Last change |
| --- | --- | --- |
| Settings reducer and preferences | `feature/settings/.../HomeSettingsFeature.kt`, `SettingsFeature.kt` | `bc68c787` (2026-11-16) |
| Experimental registry and keys | `core/.../ExperimentalFeature.kt`, `SharedKeys.kt` | `bc68c787` (2026-11-16) |
| Server form and custom headers | `app/.../AppFeature.kt`, `server/.../OpenCodeServer.kt` | `9b4e1d9c` (2026-11-20) |
| Diagnostics report | `core/.../diagnostics/ProblemReport.kt` | `24c96b93` (2026-11-18) |
| Pairing scanner | `feature/settings/.../servers/PairingScanner.kt`, `ServerCameraClient.kt` | `5e4b4219` (2026-11-16) |
| What's New catalogue | `feature/settings/.../whatsnew/entries/*.kt` | `f79a895e` (2026-11-14) |
| Model/agent catalogue | `server/.../live/LiveCatalog.kt`, `model/Models.kt` | `8233821d` (2026-11-14) |
| Autocomplete and mentions | `feature/composer/.../Autocomplete*.kt`, `server/.../model/Composer.kt` | `f79a895e` (2026-11-14) |
| Folder browser | `feature/session/.../FolderBrowserFeature.kt` | `f79a895e` (2026-11-14) |

## Acceptance matrix

| Behaviour | Evidence and contract | iOS implementation | Verification | Status |
| --- | --- | --- | --- | --- |
| Settings is a full-screen surface reachable from the drawer | `SettingsFeature`, `SettingsPresentation`, `HomeView` settings row | Gear in the drawer toolbar; `SettingsFeature` and `SettingsView` in a full-screen cover over Home | `SettingsUITests` opens, edits and closes it; screenshots | done (simulator) |
| Settings navigation and back | `SettingsFeature.path`, page enum | `SettingsPage` stack with `NavigationStack`; system back and Done | onboarding/diagnostics/server pages in UI tests | done |
| Typed preference defaults | `SharedKeys.kt`, `ThemeSharedKeys`, experimental keys | `SettingsPreferences` with explicit `SharedKeys` defaults | `SettingsFeatureTests.defaults`; `SharedStoreTests` | done |
| Safe schema migration and restore race | delayed restore must not overwrite a choice | typed keys decode defaults; `edited` set fences `preferencesLoaded` | `restoreDoesNotOverwriteAnEdit` | done |
| Failed preference write is not reported as saved | explicit storage outcomes | write result checked, prior value kept, `saveProblem` shown | `failedPreferenceWrite` | done |
| Appearance | `AppTheme`, `AppearanceColorScheme` | System/Light/Dark stored as `appearance-color-scheme`; app root applies it | unit + relaunch journey + light/dark screenshots | done for supported choices |
| Return key preference | `return-key-sends` (false) | native `ComposerTextInput` consumes it; plain Return sends or inserts a newline, Shift+Return always inserts, marked text passes through, and the request-answer bar routes its Return to the request only | `ComposerReturnKey` unit tests; two simulator journeys cover before/after relaunch and the request bar | done |
| File wrap preference | `file-viewer-wraps-lines` (false) | Settings and the open file viewer both write the key; code rendering switches between wrapping and horizontal scrolling live | 3 file-viewer reducer tests; simulator before/after relaunch plus live-toggle journey | done |
| In-App Browser experiment | `experimental-in-app-browser`, off | Experimental switch writes the audited key; P10 browser reads it; disabling closes the open browser | unit, UI toggle, P10 browser gate retained | done |
| Other audited experiments | `ExperimentalFeature` registry | not shown where this build has no implemented behaviour; no inert controls | decision D-94 | documented adaptation |
| All Experiments | `AllExperiments` keys and skips | not built because only one supported experiment would make the control misleading | decision D-94 | not adopted |
| Server identity and credentials | `OpenCodeServer`, Keychain shared keys | one serialized boundary covers Settings, pairing/connection persistence, forget-all and saved-data replacement; ordinary writes refuse corrupt records; confirmed replace/forget recover corrupt records while preserving raw before-state for rollback; selected/list stay coherent; edits are fenced by operation ID and previous identity; drafts transfer before reconnect/disconnect | `ServerWriteTransactionTests`, `SavedDataRecoveryTests` (7 malformed-storage cases), `ServerEditIntegrationTests`, Settings fencing test | done |
| Custom header name/value validation | `Header.hasValidName`, `hasValidValue` | token-character names, scalar newline refusal, blank-row refusal | `headerPolicy`, `invalidFormKeepsPriorServer` | done |
| Forbidden transport headers | audited request builder overrides `Authorization`; transport owns framing | `Authorization`, `Proxy-Authorization`, `Host`, `Content-Length`, `Transfer-Encoding`, `Connection`, `Keep-Alive`, `Proxy-Connection`, `Upgrade`, `TE`, `Trailer` refused | header policy unit test | done |
| Header persistence and prior configuration | save only after validation | form validates; App writes Keychain only on success; failure keeps the old server and edits | `saveFailureKeepsPriorServer`, `ServerHeaderTransportTests`, UI header journey | done |
| Headers bound to origin | `matchesOrigin`, redirect rule | existing `HTTPRequest`/`HTTPRedirectRule`; headers never cross an origin | P4 redirect tests retained; `ServerHeaderTransportTests`; cache-scope test | preserved |
| Header change invalidates authenticated cache | cache scope over credentials | `authenticationScopeMaterial` includes sorted sendable headers; media scope hashes it | `headerChangeInvalidatesAuthenticationScope`; P10 cache tests | done |
| Remove server confirmation | Settings/Home server removal | destructive alert; forgets saved credentials only, leaves drafts/media | unit delegate coverage and UI alert | done |
| Diagnostics allowlist | `ProblemReport`, `HidesFromProblemReports` | `DiagnosticFacts` has only version/build, phase, failure kind, status, counts; fixed-order text | `diagnosticsPrivacy` rejection list | done |
| Diagnostics are user initiated and bounded | Settings/diagnostics | Collect then Copy; no automatic dumps | `diagnosticsCollectAndCopy` UI journey | done |
| Onboarding/help without credentials | welcome steps, help copy | three-step guide and help page in Settings; completion stored; no server or camera required | `onboardingFinishesOffline`, UI journey, screenshot | done |
| QR camera boundary | CameraX/AVFoundation scanner, explicit confirmation | `PairingScannerClient` AVFoundation metadata boundary; simulator injects decoded payloads; shell still confirms and redeems | `SettingsUITests.testInjectedQR...`; unit duplicate gate | device-verified under P12: physical capture, confirmation before redemption, exactly-once redemption, expired code and denial UI |
| Duplicate scan protection | pending confirmation, no silent redemption | `handledScans` gate and shell pending confirmation; scanner has no transport | `scanIsForwardedExactlyOnce` | done |
| Expired/unsupported pairing | shell `PairingProblem` | existing P4/P5 parser and redemption errors reused | P4 pairing tests retained | preserved |
| What's New shipped catalogue | 182 Kotlin entry files + English resources | generated `WhatsNewCatalogue` from those files; IDs/days/copy retained | `WhatsNewCatalogueTests` (count, uniqueness, copy) | done |
| What's New seen state | `whats-new-seen` | existing Home seen-state written on close | P6 tests plus catalogue tests | preserved |
| What's New Try It | entry destinations | implemented: new session, Settings pages, In-App Browser experiment; every other destination is explicitly unavailable | destination honesty test; UI row rendering | done with documented unavailable routes |
| Model catalogue | `GET /api/model`, optional `/api/model/default` | `ModelCatalog`, `ServerModel`, short names, variants, default | `CatalogOperations`, fixture UI, model picker journey | done in fixture; live catalogue unverified |
| Model selection scope | per-session current/pending model | composer `selectedModel`; new-session default from catalogue; no global competing source | unit + UI | done |
| Reasoning variants | `ModelVariant.label/sorted`, `variants` | picker shows ordered variants; selected variant snapshotted | unit (variant order/label) and picker UI | done |
| Agent/mode selection | `GET /api/agent`, choosable primary/all | composer `selectedAgent`; server default option; choosable filter | unit + UI | done |
| Selection applied before send | `POST /api/session/{id}/model`, `/agent` immediately before prompt; not for queued | `SessionFeature.startComposerSend` applies agent then model once, skips queued delivery; cancellation is checked after each dependency returns; refusal fails the send | `sendAppliesSelectionBeforePrompt`, `refusedSwitchDoesNotPost`, `cancellationAfterAgentPreventsLaterMutations` | done |
| Durable send configuration | `PendingPrompt.model/agent/mentions` in persistence | `ComposerDraft`/`ComposerOutbound`/`FailedComposerSend`/`ComposerSend` carry model, agent, chips; restart restores them | outbound/retry tests retained; autocomplete prompt test | done |
| File autocomplete | `GET /api/fs/find`, limit, location | `findFiles`, 250 ms debounce, 12 rows, location-scoped generation fence | pure autocomplete tests; UI suggestion journey | done |
| Agent/skill/command suggestions | `GET /api/agent`, `/api/skill`, `/api/command` | loaded per directory, bounded rows, fuzzy title/subtitle filtering | autocomplete tests + UI | done |
| Trigger and caret safety | `AutocompleteTrigger.detect`, chip ranges | UTF-16 trigger detection; caret inside a committed chip does not reopen; marked IME text closes suggestions | detection tests, composition boundary in bridge | done for logic; physical Japanese marked text and real LAN suggestion insertion verified under P12 |
| Query/race fencing | session/directory/query/generation | file result carries generation + server + directory + query and is ignored if any changes | reducer guard plus pure tests | done |
| Mention wire shape | `OpenCodeAutocompleteMentions`, `Prompt.Mention`, file URI | each committed occurrence owns a unique ID plus UTF-16 range; editor replacements shift or invalidate it; send validates the stored range and never searches display text | 11 autocomplete tests cover duplicates, repeated picks, edits, Unicode and encoding; reducer edit test | done |
| Session mentions | desktop session chips (`@session:<id>`) | not built in P11; plain text only | documented limitation | deferred |
| Remote folder browser | `FolderBrowserFeature`, `GET /api/fs/list` | `FolderBrowserFeature`, on-demand route loads, back/cancel/retry/loading/empty/error | `FolderBrowserTests` + UI selection/cancel | done |
| Remote paths stay remote | `AgentFileReference`, fs routes | no `FileManager` use in browser; only server paths navigate | tests use scripted client paths | done |
| Folder selection preserves draft | `DraftProjects` route selection | `projectDirectoryChosen` changes a new session's directory without clearing text | unit + UI cancel/selection journey | done |
| Attachment vs server-file reference | P10 staged files vs `file://` mentions | separate types and metadata; autocomplete files never touch local storage | prompt shape test | done |
| P8–P10 regression coverage | P8 transcript, P9 composer, P10 media | untouched boundaries retained; package suite passes | full package run | preserved |

## Defaults and persistence keys

| Value | Key | Default | Storage |
| --- | --- | --- | --- |
| Appearance | `appearance-color-scheme` | `system` | UserDefaults |
| Return sends | `return-key-sends` | `false` | UserDefaults |
| Wrap file lines | `file-viewer-wraps-lines` | `false` | UserDefaults |
| In-App Browser | `experimental-in-app-browser` | `false` | UserDefaults |
| Onboarding completed | `onboarding-completed` | `false` | UserDefaults |
| Servers and credentials | `saved-server`, `saved-servers` | absent/empty | Keychain |
| What's New seen | `whats-new-seen` | empty | UserDefaults |

## Deliberate adaptations

- Only the In-App Browser experiment is surfaced. Android's other switches either gate features
  owned by P12/P13 or have no iOS implementation; showing them would be inert.
- Return and Wrap Lines now drive the native input and code viewer; no inert preference remains.
- The model catalogue's default route is optional: an older server without `/api/model/default`
  keeps a usable catalogue with no default.
- Session mentions are not reproduced; commands, skills, agents and files are. Occurrence identity and ranges are maintained instead of searching tokens.
- No live V2 server with `/api/model`, `/api/agent`, `/api/skill`, `/api/command` or `/api/fs/find`
  was available. Request/decoding shapes are tested against fixtures and the audited Kotlin.

## Remaining acceptance checks

| Check | Owner | Acceptance |
| --- | --- | --- |
| Physical camera scan, permission denial/restriction | P12 | Scan a valid `opencode pair` code on a phone; confirmation appears once; denied/restricted camera is a typed outcome |
| Physical IME marked text, hardware Shift+Return | P12 | Compose in Japanese/Chinese input; suggestions never commit marked text; Shift+Return inserts a newline |
| Keychain persistence on a signed build | P12 | Edit a header, relaunch, server connects with the header; denied Keychain leaves the old server usable |
| Live model/agent catalogue | P12 (server prerequisite) | A compatible V2 server lists models/agents; picker, reasoning level and first send match the wire |
| Try It destinations unavailable in this build | P14 or the owning feature | Each unavailable destination either gets a real route or stays labelled unavailable |
| Session mentions | P14 | `@session:` chips resolve to exact `@session:<id>` tokens and mention ranges |
