# AUDIT — read-only reconstruction audit before Swift implementation

**Audit time:** 2026-11-21T18:28:04Z (ref snapshot); machine checks to 18:45Z.
**Auditor action:** read-only. No checkout change, commit, branch, push or PR. No `ios/` branch created.

Artifacts in this folder: `AUDIT.md`, `BRANCHES.md`, `branches.json`, `FEATURE_MAP.md`, `PROTOCOL.md`, `IOS_GAPS.md`, `ASSET_PROVENANCE.md`, `PLAN.md`.
Audit clone (outside the checkout): `<audit-directory>/mirror.git` (bare mirror, 226 MB) and extracted trees under `.../work/`.

---

## 1. Checkout verification (unchanged)

```
$ git status --porcelain=v2 --branch
# branch.oid 1380772dc44f0261c43b65f130eb43c5c71860da
# branch.head dev
# branch.upstream origin/dev
# branch.ab +0 -0                    <- stale tracking info, see below

$ git remote -v
origin    https://github.com/Rift7/opencode-ios.git        (fetch/push)
upstream  https://github.com/anomalyco/opencode-android.git (fetch/push)

$ git ls-remote --symref origin HEAD
ref: refs/heads/dev	HEAD
7358160e808fb1870eeb20f5da8df832667019d1	HEAD
```

- **Target confirmed:** `Rift7/opencode-ios`. It is a **fork whose content is the Android/Kotlin app**; `upstream` is `anomalyco/opencode-android`, the real source project. The name "opencode-ios" is misleading — this is not the Swift repo.
- **Default branch:** `dev` (the fork's `HEAD` symref). Upstream's `dev` is the same commit `7358160e`.
- **Upstream vs origin:** upstream has **156** branches, origin **157**. The only difference is `compose-bom-2026-11`, which exists on the fork only. No branch exists upstream that is missing on origin, and both `dev` tips are identical.
- **Local checkout is one commit behind and clean.** Local `dev` = `1380772d` ("fix(transcript): stop list items crashing the transcript on scroll (#261)"); `origin/dev` = `7358160e` ("chore(deps): update Compose to 1.13 (#265)"). `git rev-list --count 1380772d...7358160e` = `0 1`. The `branch.ab +0 -0` line is stale local tracking data, not a modification. **This audit uses `7358160e` as current dev**, and the checkout was never fetched or moved.

## 2. Branch enumeration

Method: `git clone --mirror` of origin (all refs, full history; no shallow or single-branch fetch), then `git for-each-ref refs/heads` — an unrestricted listing, not a UI page.

- **157 heads including `dev`** (matching the planning snapshot's 157, refreshed: `dev` is still `7358160e`).
- **13 tags:** `dev-latest` `1380772d`, `v0.2.2`, `v0.3.0`, `v0.3.8`, `v0.3.10`, `v0.6.3`, `v0.6.4`, `v0.7.0`, `v0.8.0`, `v0.8.1`, `v0.8.2`, `v0.8.3`, `v0.8.4` (`4c1e0054`).
- Every branch's immutable head SHA, tip date, merge base, ahead/behind, unique-commit count, patch-equivalence count, net path count and top-level areas are recorded in **`branches.json`** and tabulated in **`BRANCHES.md`** with a disposition for each.

Category totals (156 non-dev branches):

| Category | Count | Meaning |
| --- | --- | --- |
| `integrated-ancestor` | 124 | tip is an ancestor of `dev`; behaviour is in dev (consult dev source) |
| `divergent` | 25 | unique commits not in dev |
| `empty-diff` | 2 | `port-toolbounds`, `strings-xml-migration` — zero net paths vs merge base |
| `patch-equivalent` | 1 | `proto-send-native` — its one commit is patch-equivalent to work already in dev |
| `unrelated-history` | 4 | `glass-perf`, `glass-lens-candidate`, `glass-look`, `webrtc-spike` — **no merge base with dev** |

The four unrelated branches are a linear stack of the same pre-rewrite history (`glass-perf` ⊂ `glass-lens-candidate` ⊂ `glass-look` ⊂ `webrtc-spike`, by commit containment) with **633–662 files each**, ~400 under `app/src` and 100–169 under `docs/port`. Their trees were inspected independently: they are an older Android-port snapshot, and their only Swift is the capture harness. **Nothing from them was merged or treated as a feature delta.**

Deduplication: the glass stack collapses to one line of development ending at `webrtc-spike`; `background-run-connection` ⊂ `-notices` ⊂ `-replies`; `play-crashes` ⊂ `play-crashes-ci`; `sync/*` and `port-*` branches are all ancestors of dev (staging snapshots of syncs already landed).

## 3. Search for iOS artifacts across all tips and history

Searched every ref's tree (`git ls-tree -r`) and the whole history (`git log --all --diff-filter=A`) for `.swift`, `.xcodeproj`, `.xcworkspace`, `project.yml`, `.entitlements`, `.plist`, `Package.swift`, `.pbxproj`, `.xcconfig`, fonts, licences, fixtures, protocol specs.

Result: **only four Swift-related files exist anywhere**, all in `scripts/ios-reference/` on the four unrelated branches:

| File | What it is |
| --- | --- |
| `CaptureHost/CaptureHostApp.swift` (10 lines) | stub host app, `Text("Capture host")` |
| `CaptureUITests/CaptureTests.swift` (486 lines) | XCUITest driver against the **installed** app, bundle id `ai.opencode.mobilecode` |
| `Capture.xcodeproj/project.pbxproj` (296 lines) | capture targets only |
| `Capture.xcodeproj/.../Capture.xcscheme` | scheme |

**Verdict:** that is a capture harness, not application source. The harness is nevertheless the single most valuable artifact recovered, because it encodes the original app's **accessibility identifiers, UI copy, gesture timings and lab launch protocol** (documented in `FEATURE_MAP.md` §12).

No other iOS code, plist, entitlement, `project.yml` or Xcode project was recoverable. `dev` does not contain `scripts/ios-reference` or `docs/port` at all.

Reference images: 68 PNGs at `docs/port/reference/ios/`, 1320×2868 px, iPhone 17 Pro Max simulator, iOS 27.0, status bar 9:41 — **`glass-look`/`glass-lens-candidate` at iOS `d809b1e`; `webrtc-spike` at iOS `16b40f7`** (58 files changed) even though every MANIFEST still claims `d809b1e`. Inspected as images; details in `ASSET_PROVENANCE.md`.

## 4. Deep inspection of dev

Read at `7358160e`: `README.md`, `AGENTS.md`, `settings.gradle.kts`, root build files, `gradle/libs.versions.toml`, the app entry (`OpenCodeApplication.kt`, `MainActivity.kt`, `AppFeature*.kt`, `AppView.kt`), all twelve source areas (`core`, `server`, `app`, `feature/{media,voice,system,transcript,composer,settings,session,drawer}`, `devtools`), the server live implementations and wire models, retry/SSE, shared storage, experiments, string resources and the JVM test corpus.

Inventory: **1,365 Kotlin files** — `feature` 1,082, `server` 111, `core` 107, `app` 45, `devtools` 19, `build-logic` 1.

Extracted for the rebuild: `PROTOCOL.md` (routes, SSE, models, retry, errors), `FEATURE_MAP.md` (feature → entry point → reducer → dependencies → persistence → wire → cancellation → errors), `IOS_GAPS.md` (iOS-only/partial/dropped), `ASSET_PROVENANCE.md` (fonts, images, icons, licences).

Documentation read: `docs/parity/` (12 area files + `core-ui.md`, `README.md`, `sync.json`, 15 sync plans), `docs/releasing.md`, `docs/translating.md`. The parity corpus maps ≈620 iOS file rows and 269 icon rows onto Kotlin, and records 2,858 ported / 268 deleted tests as of its last audit — **a historical count, not current**.

## 5. Toolchain verification (no substitution)

```
xcode-select -p        /Applications/Xcode.app/Contents/Developer
xcodebuild -version    Xcode 27.2   Build 27B52
swift --version        Apple Swift 6.4.2 (swiftlang-6.4.2.1.9), target arm64-apple-macosx27.2.0
xcodebuild -showsdks   iOS 27.2 (-sdk iphoneos27.2), Simulator iOS 27.2
xcrun simctl runtimes  iOS 27.2 (24B8117), iOS 27.0, iOS 26.5
OS                     macOS 27.2.1 (26B131), arm64
```

**Requested toolchain is present exactly**: Swift 6.4, Xcode 27.2, iOS 27.2 SDK and simulator runtime. No fallback was used.

Dependency probe (outside the checkout, `.../tca-probe`): a Swift 6.4 package pinned to **TCA `1.26.2`**, platform `.iOS(.v27)`, built for `generic/platform=iOS Simulator`.

- Resolution picked: TCA 1.26.2, swift-dependencies 1.17.2, swift-sharing 2.10.1, swift-navigation 2.11.2, swift-perception 2.0.12, swift-syntax 604.0.0, swift-clocks 1.1.1, swift-issue-reporting 2.1.2.
- First attempt **failed**: `Macro "ComposableArchitectureMacros" … must be enabled before it can be used` (and the same for CasePaths/Dependencies/Perception/Navigation macros). This is Xcode 27's macro-trust gate for SPM plugins.
- With `-skipMacroValidation`: **BUILD SUCCEEDED**. The plan must pass this flag in CI or commit macro-trust settings; otherwise every build fails in a fresh checkout.

Upstream facts checked from the packages themselves: TCA `1.26.2` declares `swift-tools-version: 6.4`, `swiftLanguageModes: [.v6]`, `platforms: [.iOS(.v16), …]`; its release notes for `1.26.0` include "Fixed: Xcode 27 Beta 1 Support". `main` is already tools-6.4 as well, so no separate "Swift 6.4 fork" is needed.

## 6. Freshness gate

Every historical claim carries a source commit, date and applicability. Summary of the gates that matter:

| Evidence | Source | Date | Compared with | Verdict |
| --- | --- | --- | --- | --- |
| iOS architecture/protocol/state/ui docs | `docs/port/explore/*`, `ios-architecture.md` @ `glass-look` | 2026-10-07 | iOS `4fb5e0e` | **Superseded in places**: 9 corrections recorded in `ios-architecture.md` itself; treat as description of an October app |
| iOS deviations | `docs/port/deviations.md` @ `webrtc-spike` | 2026-10-08 | iOS `16b40f7` | Applicable to October; Android has moved on |
| iOS reference screenshots | `reference/ios` | 2026-10-08 | `d809b1e` (3 branches) / `16b40f7` (`webrtc-spike`) | **Manifest is stale** for `webrtc-spike`; use its images as the newest |
| iOS parity rows | `docs/parity/*` @ dev | sync `01eef583`; files touched to 2026-11-21 | current dev | Applicable as a map; counts are historical |
| Voice behaviour | `voice-brief.md`, `voice-ios-issues.md` | 2026-10-08 | iOS `998cb16`, contract `d021b9f` | **Uncertain**: held-result rule explicitly untested; iOS later moved to WebRTC |
| Glass/backdrop | `perf/glass-blur.md` | 2026-10-08 | Android host GPU | "No phone was measured" — not a product requirement |
| iOS 27 glass rendering | `glass-look`, `system.md` | 2026-10-08 | iOS 27.0 simulator | **Uncertain**: reports are simulator observations; private `variableBlur` is an App Store risk |
| `feat/assistant` | divergent branch | reverted in dev (`bc68c787`) | dev | **Superseded/reverted** — not current behaviour |
| `ios-sync-911ab132` | divergent branch | ported into dev by later syncs | dev | **Already integrated** |
| `ui/material-native` | divergent branch | 468 behind | dev design system | **Superseded** |

Rule applied throughout: October evidence never overrides current dev behaviour or current Apple APIs; where it conflicts, the conflict is recorded rather than resolved silently.

## 7. Findings that change the plan

1. **The requested "original iOS repository" is not recoverable here, and the repo named `opencode-ios` is the Android app.** Reconstruction must run from Kotlin + parity corpus + the capture harness + screenshots. No claim of pixel parity is possible or permitted.
2. **There is no iOS app source to port.** The rebuild is a native reimplementation guided by the parity map, the protocol, and the porting dossier.
3. **The dossier describes an iOS app that no longer exists in that shape**: it predates the WebRTC voice move, and its glass/UIKit notes are simulator observations from October. iOS 27 patterns must be chosen fresh.
4. **TCA is viable and already Swift-6.4-ready**, but the macro-trust gate is a build-blocking detail.
5. **The Android app's visual system is the desktop one (Inter/OpenMono, flat hairlines), not the recovered iOS one (SF, Berkeley Mono in onboarding).** This is a genuine fork in requirements, not a translation detail.
6. **Branch evidence has almost no iOS-specific code**: the only unique iOS-relevant branch content is the 68 screenshots and ~180 KB of Markdown.
7. **Two branch families are traps**: `ui/material-native` (468 behind, would undo the design system) and `feat/assistant` (reverted by `bc68c787`).
8. **`agent-widgets` is not a home-screen widget feature** — it is an in-app agent-generated UI renderer ported *from* an iOS branch, requiring a native runtime. It is out of scope for an iOS rebuild until that iOS branch lands.

## 8. Unresolved questions (with defaults)

| Question | Default proposed |
| --- | --- |
| Which iOS baseline is "current"? | The synced parity point `01eef583` plus current dev behaviour; October captures are reference, not spec |
| iPhone-only or iPad? | iPhone only; no iPad work until product requirements demand it (per instructions) |
| Deployment target iOS 27.2 vs iOS 18 historical? | **27.2**, as instructed; note that historical evidence is an iOS 18 app, so availability branches are not needed |
| SF vs Inter/OpenMono? | Follow the audit: SF for UI, SF Mono for code, Berkeley Mono only if a licence is supplied. Recorded as native decision |
| Glass? | Use current SwiftUI glass for control surfaces only; no private filter |
| Signing identity / bundle id / App Group | Owner-supplied; historical values are evidence only |
| Push notifications | Out of scope until a relay exists; Experimental and off |
| Voice calls | Deferred behind Experimental; protocol documented |
| Realtime/video WebRTC | Deferred; no iOS evidence recovered beyond protocol notes |
| iPad | Deferred |

## 9. Repository-unchanged confirmation

`git status` and `git for-each-ref` were re-run after the audit; output is reproduced at the end of `PLAN.md` and in the audit transcript. The target checkout was never fetched, checked out, staged, committed or rebased; no branch was created; nothing was pushed.
