# ASSET_PROVENANCE — iOS reconstruction evidence

Audit time: **2026-11-21T18:28:04Z** (git snapshot), machine checks 2026-11-21 ~18:30–18:45Z.
Target checkout: `<repository-root>` (origin `Rift7/opencode-ios`, branch `dev` at `1380772d`, clean).
Evidence source: mirror clone of origin at `<audit-directory>/mirror.git`, plus extractions under `.../work/`.

The original iOS app repository (`anomalyco/opencode-ios`) is **not** available in this environment and was not fetched. Everything below is evidence *about* it recovered from this repository, and is labelled by confidence.

---

## 1. What iOS source actually exists in this repo

Only four Swift files exist anywhere in the 157-branch history, all on `glass-perf`, `glass-lens-candidate`, `glass-look` and `webrtc-spike`, all under `scripts/ios-reference/`:

| File | Lines | Role |
| --- | --- | --- |
| `CaptureHost/CaptureHostApp.swift` | 10 | Stub host app; body is `Text("Capture host")`. Not app source. |
| `CaptureUITests/CaptureTests.swift` | 486 | XCUITest driver that launches the **installed real app by bundle id** and screenshots named states. |
| `Capture.xcodeproj/project.pbxproj` | 296 | Two targets (`CaptureHost`, `CaptureUITests`), `IPHONEOS_DEPLOYMENT_TARGET 18.0`, `TARGETED_DEVICE_FAMILY 1`, `CODE_SIGNING_ALLOWED NO`. |
| `Capture.xcodeproj/.../Capture.xcscheme` | — | Scheme. |

**Verdict: capture harness only, not application source.** `dev` does not contain `scripts/ios-reference` at all; the harness was dropped after the porting effort moved on.

`git log --all --diff-filter=A --name-only` over every ref confirms no other `.swift`, `.xcodeproj`, `.entitlements`, `project.yml`, `Package.swift` or `.xcconfig` was ever added.

---

## 2. Reference screenshots — the highest-value visual evidence

`docs/port/reference/ios/` — **68 uncropped PNGs** (plus `MANIFEST.md`), on the four unrelated-history branches only.

- Dimensions verified with `sips`: **1320 × 2868 px**, i.e. 440 × 956 pt @3x for every file checked.
- Device: **iPhone 17 Pro Max**, simulator `<reference-simulator>`, **iOS 27.0**.
- Status bar pinned to 9:41. Locale forced to `en` / `en_US`.
- 35 numbered states, `34` unused.

### 2.1 Blob history vs manifest — the freshness trap

The MANIFEST in **every** branch still says the images are from iOS `d809b1e`. That is only true for three of the four:

| Branch | `docs/port/reference/ios` tree | Actual app commit | Captured | Evidence |
| --- | --- | --- | --- | --- |
| `glass-perf` | `—` (78 images, subset) | `553a407` | 2026-10-07 | oldest set; no iOS-only deviation sections yet |
| `glass-lens-candidate` | `2128d5d1…` | `d809b1e` | 2026-10-08T04:58+05:30 | commit `96e2dfc3 docs(port): refresh the iOS baseline at d809b1e` |
| `glass-look` | `2128d5d1…` (identical to above) | `d809b1e` | 2026-10-08T04:58+05:30 | same |
| `webrtc-spike` | `a27f8076…` (**58 files differ**) | **`16b40f7`** | 2026-10-08T09:48+05:30 | commit `b30883c3 docs(port): refresh the iOS baseline at 16b40f7`; MANIFEST **not** updated |

So the best image set is **`webrtc-spike` at `16b40f7`**, not the manifest's claimed `d809b1e`. That commit message also records a caveat: the recapture reused fixtures "already running from the shared checkout", so the fixtures served that checkout's session lab rather than `16b40f7`'s.

Matching Android captures exist at `docs/port/reference/android/` (same 35 states, 69 files) on the same branches, captured 2026-10-07/08 for pixel comparison.

### 2.2 States captured (from MANIFEST tables)

`01` first launch · `02` server manual · `03` connect error · `04` drawer · `05` drawer search · `06` new-session draft · `07` transcript markdown · `08` transcript tasks · `09` transcript table · `10` transcript links · `11` tools collapsed · `12` tools expanded · `13` subagent · `14` images · `15` running · `16` streaming · `17` composer text · `18` composer attachments · `19` composer steer menu · `20` permission · `21` question · `22` header context · `23` session menu · `24` session sheet · `25` model picker · `26` attachment menu · `27` background work · `28` shell output · `29` Catch Up · `30` What's New · `31` settings · `32` diagnostics · `33` error banner · `35` composer empty.

### 2.3 What the images objectively show (inspected as images)

Recorded only where the pixel content is unambiguous; no claim of pixel parity with an unavailable app.

- **Drawer (04 dark):** title "Sessions"; a Search field; rows "Catch Up" with a trailing count (9) and "What's New" with a dot, both with blue-tinted glyphs; sections "Pinned" then "Recents"; per-row status dots (blue = idle/read-state dot, orange = one distinct state, a spinner for running); a "New Session" pill bottom-left and a circular gear button bottom-right; the drawer is a ~75 % width panel over the session page, whose glass cards ("Project", "Model", "Message") remain visible and dimmed to the right.
- **Transcript (07 light):** large display heading, body prose, a fenced code block drawn as a full-width band with a hairline top/bottom and syntax colouring, inline code chips, task-list checkboxes, a small copy glyph under the assistant reply, floating header with hamburger circle, title + subtitle stack, and ellipsis circle; a floating jump-to-bottom circle above the composer; the composer pill is translucent with `+`, "Message" placeholder and a mic.
- **Attachment menu (26 dark):** a glass panel growing from `+` with rows Camera / Photos / Files, and a separate system "Paste" capsule below; the composer's `+` has become `×`.
- **Approval (20 light):** a bottom sheet titled "Run Command?" with a close circle, a folder-glyph circle, monospaced command text, then "Deny" / "Always Allow" side by side and a filled blue "Allow Once" full-width button.
- **Settings (31 dark):** a sheet titled "Settings" with a Done capsule; a green dotted "Connected" card with `127.0.0.1:4110` and a Change button; a grouped list with coloured icon tiles — Notifications (red), Voice (purple) "Off", Diagnostics (teal); then a separate "What's New" row with an orange icon.
- **Catch Up (29 light):** header "9 Left" with a back chevron and "Undo"; one card showing session title with chevron, project subtitle, the transcript preview with user bubbles and a "Needs your input" line, a pinned "1 pending request … Review" row, a check circle, and bottom actions "Keep Unread" / filled green "Mark as Read".
- **Background work (27 dark):** a floating panel over a dimmed transcript listing "Subagents → Review the drawer choreography" and "Shells → bun dev --port 3000  0:16", above the composer.
- **First launch (01 light):** wordmark, tagline "Keep your coding sessions moving from your phone.", three numbered steps (1 Install OpenCode on your computer with `opencode.ai/download`; 2 Run this in a terminal with `opencode pair` and a copy control; 3 Scan the QR code it prints, with the same-Wi-Fi/Tailscale note), then "Enter a Server Manually" and a black "Scan Pairing Code" pill.

---

## 3. iOS file manifest (from `docs/port/sync.json`)

The port's sync config names the iOS repo's layout — the best available inventory of the original project:

```
OpenCode/**            (app target: 86 files, 36,859 lines, one Metal shader)
OpenCodeShare/**      (share extension: 3 files, 441 lines)
OpenCodeWidgets/**    (widget extension: 2 files, 290 lines)
OpenCodeTests/**      (unit tests: 37 files, 17,332 lines)
AppIcon.icon/**
project.yml            (XcodeGen)
OpenCode/Info.plist
OpenCode/OpenCode.entitlements
OpenCodeShare/Info.plist + OpenCodeShare/OpenCodeShare.entitlements
OpenCodeWidgets/Info.plist
OpenCodeUITests/**
packages/notify-plugin/**, packages/notify-relay/**
```

Deferred iOS files: `OpenCode/SessionNotifications.swift`, `OpenCode/GlassMorphTrace.swift`.

App identity recorded as context (evidence, **not** configuration to copy): bundle `ai.opencode.mobilecode`; share `.share`; widgets `.widgets`; app group `group.ai.opencode.mobilecode`; keychain service `<historical-keychain-service>`; historical team id `<historical-team-id>`; marketing `0.1.0` build `37`; iOS 18 deployment target at port time; iPhone-only (`TARGETED_DEVICE_FAMILY 1`); `UIBackgroundModes` = `audio`; `NSAllowsLocalNetworking`.

---

## 4. Fonts

| Asset | Where | Licence | Status |
| --- | --- | --- | --- |
| **Inter** `core/src/main/res/font/inter.ttf` | Android app (all UI text) | OFL, text at `core/src/main/assets/licenses/Inter-OFL.txt` | Android port of the desktop design system; the historical iOS app used **SF** for UI text and bundled no Inter |
| **OpenMono** `openmono_regular.ttf`, `openmono_bold.ttf` | Android app (code/tool output/brand marks) | OFL, `core/src/main/assets/licenses/OpenMono-OFL.txt` | refresher `scripts/update-openmono.py` |
| **Berkeley Mono Variable** `OpenCode/Fonts/BerkeleyMonoVariable.ttf` | iOS, per `docs/port` | **no licence text found in any recovered artifact** | PostScript name `BerkeleyMonoVariable-Regular`; used only for onboarding brand marks; "do not use Berkeley Mono in the transcript" |
| Pele (Mermaid) `feature/media/src/main/assets/mermaid/LICENSE-pele.txt` | Android | Apache-2.0 (upstream project) | same engine iOS vendors under `Vendor/Mermaid/` |

**Discrepancy to preserve:** the Android app's typography is the *desktop* system (Inter + OpenMono, desktop type scale), while recovered iOS evidence says the iOS app used SF and SF Mono with Berkeley Mono only in onboarding. The migration instruction says visuals follow the audit, so this is an explicit native decision (see DECISIONS in PLAN.md), not a translation.

## 5. Images, icon and symbols

- iOS images: only four PNGs — `opencode-wordmark-{light,dark}.png` and `opencode-wordmark-simple-{light,dark}.png`, template-rendered; connection screen uses the full wordmark at 200×36. No colour asset catalogue, no theme file. Android carries vector/text versions instead (`app/src/main/res/drawable{,-night}/opencode_app_mark.xml`).
- iOS app icon: `AppIcon.icon/icon.json`, an iOS 26 Icon Composer asset — Display P3 solid `0.075, 0.063, 0.063`, one layer, `logo.svg` (820 viewBox ring, white outer, inner `#5A5858`), glass enabled, neutral shadow 0.4, translucency 0.4. The SVG survives in Android as `drawable/ic_launcher_foreground.xml`.
- Icon vocabulary: `docs/port/symbols.json` — **117 SF Symbols** mapped to Material Symbols; 23 filled, 7 mirrored, 109 "good" matches, 8 "none". (`scripts/material-symbols.txt` in dev now has 256 entries, i.e. it has grown past the recovered list; do not assume the recovered 117 is complete.)
- Provider/MCP icons: 98 + 14 SVGs under `core/src/main/assets/`, drawn with Coil SVG.

## 6. Notices to carry into the new app

1. Inter OFL and OpenMono OFL texts (ship in the app bundle, not only the repo).
2. Berkeley Mono is referenced by recovered iOS evidence but **no licence text is recoverable**; do not bundle it unless the owner supplies a licence.
3. Material Symbols are Apache-2.0 (Google) — keep the notice if icons are vendored.
4. Mermaid/Pele licence if the Mermaid renderer is used.
5. TCA and its dependencies are MIT; MIT notices ship with the packages.
6. WebKit/WKWebView use requires no notice but is subject to the "limited interface" rule in the migration instructions.

## 7. Evidence limits

- No live app binary, no Swift source, no `project.yml`, no `.entitlements`, no `Info.plist` recovered. Every statement about iOS internals above comes from the porting dossier (`docs/port/*`) or the parity corpus (`docs/parity/*`), which are *descriptions*, sometimes of commits that later moved.
- Simulator captures under-render Liquid Glass and scroll-edge blur; the docs say so explicitly.
- The harness cannot scan a QR code (no simulator camera); the attachment menu still offers Camera.
