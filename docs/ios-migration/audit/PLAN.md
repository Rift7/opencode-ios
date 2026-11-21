# PLAN — dependency-ordered rebuild of the native iPhone app

Inputs: `AUDIT.md`, `BRANCHES.md`, `FEATURE_MAP.md`, `PROTOCOL.md`, `IOS_GAPS.md`, `ASSET_PROVENANCE.md`.
Baseline for all behaviour: `dev = 7358160e808fb1870eeb20f5da8df832667019d1`. Baseline for iOS shape: parity synced at iOS `01eef583`, October captures at `d809b1e` / `16b40f7`.
Target: Swift 6.4, SwiftUI, Xcode 27.2, iOS 27.2, iPhone. Work lands only on a local `ios` branch under `ios/`.

---

## 1. Proposed architecture

### 1.1 Shape

```
ios/
  project.yml                     # XcodeGen (the original app used it too — evidence, not copied)
  OpenCodeKit/                    # local SwiftPM package: all logic, fully testable
    Package.swift                 # swift-tools-version 6.4, platforms [.iOS(.v27)], swiftLanguageModes [.v6]
    Sources/
      OpenCodeCore/               # store adapters, dependencies, sharing, tokens, logging, haptics
      OpenCodeServer/             # transport, retry, wire models, SSE, pairing, auth
      OpenCodeSession/            # session + subagent pages, background work, request review
      OpenCodeTranscript/         # rows, markdown, streaming, selection, media rows
      OpenCodeComposer/           # text input, attachments, autocomplete, drafts, outbox
      OpenCodeMedia/              # image cache, viewer, agent files, WebKit browser
      OpenCodeDrawer/             # home, drawer, projects, Catch Up, What's New routing
      OpenCodeSettings/           # settings, experiments, diagnostics, onboarding
      OpenCodeSystem/             # notifications, share handoff, Live Activities, App Intents
      OpenCodeVoice/              # voice + dictation (Experimental, off)
    Tests/                        # Swift Testing; one target per library
  OpenCode/                       # app target: App, Main, scene, resources, Info.plist
  OpenCodeShare/                  # share extension
  OpenCodeWidgets/                # widget + Live Activity extension (deferred, see P12)
  OpenCodeUITests/                # XCUITest
```

Rationale: the original project used `project.yml`, `OpenCode/`, `OpenCodeShare/`, `OpenCodeWidgets/`, `OpenCodeTests/`, `OpenCodeUITests/` (evidence: `docs/port/sync.json`). Keeping that spine makes the parity map directly usable. A local package keeps reducers and clients testable without launching a simulator and keeps compile units small.

### 1.2 State

- **TCA `1.26.2`, exact pin** (verified: tools 6.4, Swift 6 mode, iOS 16+, builds under Xcode 27.2 with `-skipMacroValidation`). Its transitive pins resolve to swift-dependencies 1.17.2, swift-sharing 2.10.1, swift-navigation 2.11.2, swift-perception 2.0.12.
- Mirror the Kotlin reducer topology, which itself mirrors iOS: `AppFeature` → `HomeFeature` → `SessionFeature`, with `WhatsNew`, `ProblemReports`, `Settings` scoped; `SessionSheet`, `ShellOutput`, `Voice`, `FolderBrowser` as `@Presents` children; `Browser`, `Dictation`, `RequestDock`, `ComposerAttachments` as scopes.
- **Preserve ordering and cancellation identity.** Port `CancelID` cases by name (see `FEATURE_MAP.md` §5). `Freshness` must remain non-`cancelInFlight` with newest-`requestID` wins. Child-first `ifLet` semantics are TCA's already.
- Do **not** replace reducers with view models; do not invent a new navigation model.

### 1.3 Concurrency and hot paths

- `@MainActor` default isolation for the app and reducers (the original project used it; it also matches the Kotlin "main-thread queue" store).
- Off-main actors: markdown parsing/caching, JSON decode of transcripts, transcript snapshot persistence, image decode/cache, media fetch, audio, diagnostics journal writes, file staging.
- Structured concurrency only; every long-lived task has an owner and a cancellation path; SSE and uploads use bounded buffers (`bufferingNewest(128)`, 75 ms/256-mutation batching).
- Swift 6 concurrency resolved by isolation/ownership. `@unchecked Sendable` requires a written justification in the file and a `DECISIONS.md` row; blanket `nonisolated(unsafe)` is forbidden.

### 1.4 Persistence and secrets

| Data | Where | Key |
| --- | --- | --- |
| Server list, pairing tokens, provider API keys | **Keychain** (owner-supplied service name) | `saved-server`, `saved-servers`, `openai-api-key`, `xai-api-key` |
| Pins, read dates, last-viewed, muted/hidden, model variants, recent models, model display names, seen watermarks | Files in Application Support | names as in `FEATURE_MAP.md` §3 |
| Transcript snapshots | Application Support, 4 MB / 16 entries / 14 days | `transcript-snapshots.json` |
| Home snapshot | Caches | `home-snapshots.json` (per server) |
| Composer drafts/attachments | Application Support + Caches, 500 ms debounce, 30-day eviction | `composer-state.json`, `ComposerAttachments/` |
| Shares | App Group | `share-targets.json`, `Shares/{uuid}/share.json` |
| Diagnostics | Application Support JSONL, manual export only | `Diagnostics/` |

Credentials never logged; log ids, counts, lengths, statuses, durations only. A redaction unit test must fail if a token/address/message body reaches the logger.

### 1.5 Design system

Follow the **audit**, and record the conflict rather than resolve it silently:

- Recovered iOS evidence: SF for UI, SF Mono for code, Berkeley Mono only in onboarding (no licence recovered), system semantic colours, Apple system text styles, radii 10/14/18, glass for controls.
- Current Android dev: Inter + OpenMono, desktop type scale, `BrandPalette`, flat surfaces + hairlines.
- **Decision D-1 (proposed):** SF + SF Mono, system colours, Apple type styles, no Berkeley Mono; glass only via public SwiftUI `glassEffect` on control surfaces. Rationale: it is the only variant supported by both the recovered iOS evidence and current Apple platforms, and it avoids redistributing an unlicensed font. Must be approved before P3 because it changes every screen.

### 1.6 Testing

- **Swift Testing** for reducers (`TestStore`-style exhaustive), dependency clients, transport decoding, SSE parsing, markdown, retry, persistence.
- **XCTest/XCUITest** for UI automation, using the recovered accessibility identifiers (`FEATURE_MAP.md` §13) where they still describe the UI.
- Isolation: every test gets a temporary directory, an in-memory Keychain double, a fake clock, an incrementing id generator, and a scripted `URLProtocol`/fixture server. **Accidental live network is a failure** — a test-only guard must reject non-fixture hosts (mirroring the Android `TestNetworkBlock`).
- Live checks are opt-in behind env vars (`OPENCODE_LIVE_SERVER`, `OPENCODE_LIVE_PASSWORD`, `OPENCODE_LIVE_SESSION_ID`, `OPENCODE_LIVE_DIRECTORY`) and skipped otherwise.

---

## 2. Work list (dependency order)

Each phase: implement → verify → update `docs/ios-migration/{STATUS,PARITY,DECISIONS,HANDOFF}.md` → commit only that phase's files on `ios`.

### P2 — Branch and scaffold
- Create `ios` **from `7358160e`** (`git worktree add ../oc-ios-migration -b ios 7358160e`), or switch the checkout if the owner prefers; never from the stale local `1380772d`.
- Add `ios/project.yml`, `ios/OpenCodeKit/Package.swift`, app target, empty test target, `.gitignore`.
- Pin TCA exactly; commit macro-trust handling (`-skipMacroValidation` in the build script, or trusted-plugin settings) because a fresh checkout otherwise fails (§AUDIT 5).
- **Gate:** `xcodebuild -scheme OpenCode -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' build` succeeds; `swift test` in the package runs at least one Swift Testing test; zero changes outside `ios/` and `docs/ios-migration/`.

### P3 — Core: store, dependencies, sharing, tokens, logging, haptics
- Dependency clients as `DependencyKey` values with inert test values; `Shared` storage incl. Keychain; design tokens (colours, type, radii, spacing), `MotionRole` equivalents, `AppLog` categories, haptics vocabulary.
- **Gate:** unit tests for path-indexed cancellation, `ifLet` child-first ordering, presented-child cancellation on dismissal, Keychain round-trip, redaction, and every shared key's default. Snapshot-free.

### P4 — Server: transport, retry, models, SSE, pairing
- `OpenCodeClient` as 38–50 operations over one transport; retry policies; SSE decoder + batcher; wire models; pairing link parse/redeem; error taxonomy.
- Build a **loopback fixture server** (Swift or the repo's Python `session-lab` when available) with scripted replies; no live dependency in CI.
- **Gate:** decoding tests for every model fixture; SSE ordering/coalescing tests; 401-stops-reconnect; backoff sequence 1/2/4/8/15 s with stable jitter; pairing validation table; request-shape assertions (query `location[directory]`, `Accept` on every call); zero live calls.

### P5 — App shell: launch, connection, pairing, manual server, reconnect
- `OpenCodeApp`, root store, scene phase, connection state machine, saved servers, QR scanner (AVFoundation/DataScanner), manual form, failure report, copy actions.
- **Gate:** reducer tests for connect/remember/retry/switch/forget; UI test for first launch → manual entry → connect error (fixture) using the recovered copy; camera path reported **unverified** if no device.
- **Screenshots:** connection + error, light and dark, committed to `docs/ios-migration/screens/`.

### P6 — Home, drawer, projects, Catch Up, What's New
- `HomeFeature`, drawer list, pins, search, status dots, server switcher, project icons, Catch Up stack, What's New.
- **Gate:** reducer tests for pin/unpin, unread, search, delete-with-backup, Catch Up mark/undo/keep; UI test for drawer and Catch Up; accessibility identifiers present; 60 fps scroll trace recorded.

### P7 — Session, subagents, background work, request review
- `SessionFeature` with the ported cancellation ids and refresh reasons; page stack; subagent family; shell/background panel; permission and form review; run lifecycle.
- **Gate:** tests for fresh-read coalescing, settlement boundaries, interrupt/stranded-steer, request answer validation, family BFS cap, two-phase delete; UI test for approval flow.

### P8 — Transcript
- Rows, tool groups, subagent cards, markdown (headings/tables/lists/code/task lists/math), streaming, selection (word/paragraph/triple-tap), new-messages divider, jump-to-latest, history paging.
- **Explicit motion decision gate (D-2):** choose SwiftUI-native scroll behaviour; do not port the Android LazyColumn motion and do not claim the original UIKit follower. Document what was chosen and why in `DECISIONS.md`.
- **Gate:** 600-token streaming test with no dropped tail; markdown golden tests; selection tests; transcript of 1,000 rows scrolls without binding churn; parsed-block cache bounded and cleared on memory warning.

### P9 — Composer
- Text input bridge (`UITextView` wrapper justified by selection/IME), attachments, autocomplete, drafts, outbox, steer/queue, pending inputs, model picker, request dock integration.
- **Gate:** draft persistence across termination; failed send retry mints a new message id; attachment upload size/type validation; IME + hardware-keyboard tests; UI test for attachment menu and steer menu.

### P10 — Media
- Image cache with disk cap (256 MiB), viewer with drag-dismiss + predictive back, agent files, WebKit browser behind a limited interface, link previews, Mermaid.
- **Gate:** cache eviction test; viewer dismiss test; browser policy tests (no arbitrary navigation); memory-pressure test.

### P11 — Settings, experiments, diagnostics, onboarding
- Settings pages, experiments (all off), diagnostics journal + manual export, onboarding, What's New entries.
- **Gate:** every experiment defaults off and is reachable; diagnostics export contains no credentials/message text (test); settings persistence tests.

### P12 — System integrations
- Share extension + App Group; Live Activities (voice/session); App Intents/Shortcuts; notifications **Experimental and off** until a relay exists.
- **Gate:** share handoff round-trip in a temp App Group; Live Activity start/update/end; notification path marked unverified if no relay/credentials.

### P13 — Voice (Experimental, off)
- Only after P4–P9 are stable. Protocol per `FEATURE_MAP.md` §10; WebRTC client; audio session ownership; raise-to-talk; dictation.
- **Gate:** unit tests for turn-taking/quiet gate/uplink watch; a hardware check is required for audio and must be reported **unverified** without a device.

### P14 — Hardening
- Performance (launch, scroll, streaming), accessibility (VoiceOver, Dynamic Type, Reduce Motion), localization scaffolding, full test pass, parity and status docs complete.

---

## 3. Measurable gates (applies to every phase)

1. `xcodebuild ... build` and `swift test` pass; warnings treated as failures where practical.
2. No test reaches the network except fixture hosts; a guard test proves it.
3. No credential, server address, pairing code, message text or file content in logs — proven by a redaction test.
4. Every new feature is behind an off-by-default switch if the Android baseline gates it.
5. `docs/ios-migration/STATUS.md`, `PARITY.md`, `DECISIONS.md`, `HANDOFF.md` updated in the same commit.
6. Every claimed behaviour cites a source path + SHA in `PARITY.md`.
7. Anything requiring hardware or credentials is recorded as **unverified**, never passed.

---

## 4. Decisions needed before or during P3

| ID | Decision | Status |
| --- | --- | --- |
| D-1 | **Typography: SF for interface text, SF Mono for code/logs/monospace. System font APIs only; no bundled font files; no Berkeley Mono, Inter or OpenMono as migration defaults.** Colour is a separate decision and keeps the established brand direction through native semantic colour tokens. | **Approved (owner)** |
| D-2 | Transcript motion | Open — SwiftUI-native, no follower/flight; document departure |
| D-3 | Composer text input | Open — `UITextView` bridge for selection/IME fidelity; SwiftUI `TextField` where sufficient |
| D-4 | Photo picking | Open — system `PhotosPicker`; no in-app photo sheet |
| D-5 | Glass | Open — public `glassEffect` on control surfaces only |
| D-6 | **Branch/worktree: native implementation in a separate worktree; the existing Android checkout stays untouched.** Integration branch `ios` created directly from the audited `origin/dev` commit. | **Approved (owner)** |
| D-7 | Bundle id / signing / App Group / Keychain service | Owner-supplied, portable configuration only; historical values are evidence, never copied |
| D-8 | iPad | Out of scope |
| D-9 | Push | Experimental, off, blocked on relay |

### D-1 consequences

- Interface text: `.body`, `.headline`, `Font.system(...)`, `UIFont.preferredFont(forTextStyle:)`; no `Font.custom`, no `UIAppFonts` entries, no font resources in the bundle.
- Monospace: `Font.system(.body, design: .monospaced)` / `UIFont.monospacedSystemFont`; code, tool output, logs and diagnostics.
- The desktop/Android type *scale* may still inform sizes and weights where the audit recorded them, but only through system font APIs.
- Colour: native semantic tokens (system backgrounds, labels, separators, plus the brand accent family), kept in one token layer so appearance and high-contrast behaviour come from the platform. Typography approval does not settle colour, and colour does not reintroduce bundled fonts.

### D-6 consequences / baseline record

- Worktree: `<migration-worktree>`; the existing checkout at `<repository-root>` is not switched, reset or modified.
- Integration branch `ios` at `7358160e808fb1870eeb20f5da8df832667019d1` (full SHA re-verified against `git ls-remote` at Phase 2 start; unchanged since the audit).
- Task branches from `ios` per issue (`ios-foundation`, `ios-networking`, …).
- Do not reset or overwrite an existing branch; if `ios` already exists, stop and report.

---

## 5. Delivery workflow (approved)

- **Worktree only.** Native work happens in `<migration-worktree>`; `<repository-root>` keeps the Android checkout as-is.
- **Integration branch** `ios`, created once from the audited `origin/dev` commit `7358160e…`. Recorded before any implementation. Never reset or overwrite an existing `ios`.
- **Task branches** from `ios`, one per implementation issue (`ios-foundation`, `ios-networking`, `ios-app-shell`, …). Coherent commits per task branch; run the relevant checks before pushing.
- **Push and draft PR** to `Rift7/opencode-ios`, targeting that repository's `ios` branch. Each PR links its issue and reports: behaviour added, validation run, remaining gaps, screenshots where useful.
- **Never**: merge, change the default branch, publish releases, distribute builds. PRs stay for owner review.
- This supersedes the earlier "commit straight to `ios`" rule.

### Audit-disposition caveat

`BRANCHES.md` dispositions are recommendations, not instructions. Android-specific dependency bumps, packaging, ANR workarounds, R8/proguard rules, Play Vitals tooling and CI changes stay out of the iOS tree even where labelled "adopt". Only behaviour with native relevance is adopted, and then as reimplemented Swift with provenance.

---

## 6. Portable documentation and privacy rules

- Committed/shared material must not depend on any developer's machine. Use `<repository-root>`, `<audit-directory>`, `<migration-worktree>` for locations outside the repository; use repository-relative paths (`ios/`, `docs/ios-migration/`) inside it.
- Never include: personal absolute paths, usernames, home directories, machine names, device identifiers, personal email addresses, private server addresses, credentials, signing identities or historical Apple team identifiers — in docs, comments, fixtures, commit messages, PR bodies, screenshots or handoffs.
- Keep: repository-relative source paths, public repository URLs, commit SHAs, API routes, protocol identifiers.
- Before copying the audit into the repository: sanitize a copy, preserve technical meaning and provenance, leave the external originals intact. Sanitized copies live in `<audit-directory>/portable/`.
- Before every commit: review staged files and screenshots for personal information. Signing and environment-specific settings come from portable configuration, not committed values.

### Macro-validation finding (scope)

- **Reproduction:** fresh SwiftPM resolution of TCA 1.26.2 into a package with no prior trust state, then `xcodebuild -scheme <pkg> -destination 'generic/platform=iOS Simulator' build` fails with, for each plugin: `Macro "ComposableArchitectureMacros" from package "swift-composable-architecture" must be enabled before it can be used` (also CasePaths, DependenciesMacros, PerceptionMacros, SwiftNavigationMacros).
- **Scope:** Xcode 27.2 / Swift 6.4 macro plugin trust for SPM dependencies; every fresh checkout and every clean CI machine, not incremental builds.
- **Fix:** narrow, documented trust for the specific packages — either committed per-package trust settings in the project, or `-skipMacroValidation` **only** in the scripts/CI invocations that build this project. Do not change global Xcode preferences or disable validation machine-wide.
- **Verification:** build succeeds with the scoped flag; a build without it is expected to fail and is documented as such.

---

## 7. Risks

1. **Behaviour drift**: current dev is 6 weeks ahead of the only iOS descriptions. Mitigation: treat dev code/tests as baseline; label every October claim.
2. **Motion expectations**: the original feel is unrecoverable. Mitigation: D-2, never claim parity.
3. **Protocol drift**: dev has routes the iOS docs never saw. Mitigation: `PROTOCOL.md` separates them; implement dev's contract.
4. **Scope explosion** (voice, widgets, assistant, agent widgets). Mitigation: Experimental/off, sequenced last.
5. **Toolchain traps**: macro validation; iOS 27.2-only APIs; simulator-only glass differences.
6. **Keychain/App Group**: blocked on owner configuration; never fabricate.

---

## 8. Open questions

1. ~~Branch location~~ — resolved: separate worktree (D-6).
2. ~~Berkeley Mono licence~~ — resolved: not used (D-1).
3. Is an Apple Developer team / bundle id available for device and push checks?
4. Should the app reuse the recovered bundle id shape or take a new owner-supplied one?
5. Is any App Store/TestFlight distribution intended in the near term (affects notifications/background modes)?

---

## 9. Repository state after the audit

```
$ git status
On branch dev
Your branch is up to date with 'origin/dev'.

nothing to commit, working tree clean

$ git rev-parse HEAD
1380772dc44f0261c43b65f130eb43c5c71860da

$ git ls-remote --heads origin dev
7358160e808fb1870eeb20f5da8df832667019d1	refs/heads/dev
```

Local `dev` is unchanged and still one commit behind `origin/dev`; no fetch, checkout, branch, tag,
staging, commit, push or PR was performed. The audit used a separate mirror clone under
`<audit-directory>` and wrote reports only there. **No `ios` branch was created.**

Phase 2 base re-check immediately before implementation:

```
$ git ls-remote --heads origin dev
7358160e808fb1870eeb20f5da8df832667019d1	refs/heads/dev
```

Identical to the audited SHA, so no intervening commits need auditing. If this differs on the next
run, audit `<old-base>..<new-base>` before choosing the base and record both.
