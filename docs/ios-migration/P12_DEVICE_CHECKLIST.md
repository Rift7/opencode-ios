# Phase 12 physical-iPhone checklist

Device run: 2026-11-25 on the connected iPhone Air, **iOS 27.3 (24C5049f)** — the requested 27.2
device was not available. Xcode 27.2, Swift 6.4.2 and the iOS 27.2 SDK were used. The signed
development build was installed in place without uninstalling the existing container. Setup,
measurements and evidence are in [DEVICE_VALIDATION.md](DEVICE_VALIDATION.md).

Status vocabulary: `passed`, `partial`, `blocked` (needs a user action, hardware or service this run
did not have) and `unverified` (not safely reproducible). A simulator pass is never promoted to a
device pass.

**Counts: 14 passed, 1 partial, 1 unverified, 4 blocked (20 checks).**

## Prerequisites

- Xcode 27.2 and a signed development build. Signing is owner-supplied; the migration does not copy
  a team, profile or production identifier.
- A compatible V2 server for catalog/network checks, or the synthetic fixture where the row allows
  it. This run used a disposable LAN fixture; no compatible live server was available.
- System Haptics on for haptic checks.
- A second display for a QR code (the Mac screen was used).

## Checklist

| Feature and prerequisite | Synthetic setup and reproducible steps | Expected result | Evidence to capture | Status |
| --- | --- | --- | --- | --- |
| Haptic vocabulary (P3) | Launch the debug app with `-hapticProbe`; play each named haptic | Each of the eleven haptics is felt and distinguishable; tap is lighter than warning/error | Probe classification lines and owner report; no device id | **passed** — all eleven distinct; `tap` lighter |
| Local-network denial (P5) | Disable Local Network for the app; connect to a LAN fixture | No fixture request arrives; the app shows the generic unreachable copy and the Local Network hint, never a false denial claim | Fixture request count and device screenshot | **passed** — 0 requests; generic copy + hint |
| Local-network allow (P5) | Repeat and allow the prompt | Fixture request arrives; Home loads | Fixture request log (address redacted) and screenshot | **passed** — real socket connected; Home loaded |
| Real-socket foreground/background recovery (P5) | Connect to a fixture; background the app, change the network, foreground it | The single shell stream reconnects; Home re-reads REST; no duplicate stream | Fixture connection count and observation | **passed** — same process; one stream; full REST re-read; header retained |
| Camera permission denied (P11) | Settings → Scan QR Code; deny camera access | Typed denied state, no crash, paste alternative remains available | Screenshot of typed state | **passed after fix** — cover stayed up with typed copy and Done/Cancel. The first build dismissed the cover; D-107 fixes it |
| Camera restricted/unavailable (P11) | Use a device with camera restriction or no camera | Typed restricted/unavailable state; no redemption | Screenshot and classification | **unverified** — not reproducible without changing restrictions or enrolling the phone |
| QR scan and confirmation (P11) | Display a synthetic QR on a second display; scan it; confirm Pair | Confirmation appears before redemption; the code is redeemed exactly once; duplicate frames do not redeem again | Screen recording/screenshot and fixture pairing log with code redacted | **passed** — confirmation before any request; exactly one redemption; scanner stops after the first frame; also reachable from the initial setup screen after the D-109 fix |
| Expired/used pairing code (P11) | Scan a code twice or wait for expiry | Typed expired/unsupported message; no credentials saved | Screenshot and redacted fixture log | **passed** — confirmation first; Pair returned 401; typed expired copy; no new credentials |
| Header persistence and Keychain (P11) | Save a synthetic proxy header; relaunch; inspect Server Details; exercise the Keychain probe | Header persists and is sent only to the server origin; a failed write keeps the old server usable | Keychain probe classification and request header names only | **passed, one sub-check unverified** — Keychain round-trip and relaunch persistence passed; header reached only the origin and not a refused cross-origin redirect; denied-write injection was not run |
| Photo/file permission and provider eviction (P10) | Pick a photo and a file; revoke Photos/Files access; evict the provider; reopen the draft | Failed import is typed; staged files remain owned; no picker URL is persisted | Recording and draft probe; no file contents | **blocked** — personal libraries were not browsed; no synthetic-only picker/provider environment |
| Playback interruption (P10) | Play a video/audio attachment; take a call or unplug headphones | Playback pauses/resumes per system audio rules; the viewer stays stable | Recording | **blocked** — no synthetic media fixture for playback and no headphone disconnect available |
| Share presentation (P10) | Share shell output and an opened file | Native share sheet presents; no credential in the payload | Recording with content redacted | **passed (manual)** — sheet presented for synthetic file text; automated tree cannot see the system share-sheet process; screenshot withheld because it showed personal contact suggestions |
| IME marked text and suggestions (P9/P11) | Compose in a CJK IME; type `@rev`, keep composition open; commit; then edit the chip | Suggestions do not query/commit during marked text; no text typed after the query is overwritten | Recording and typed draft | **passed** — underlined `@rev` showed no suggestions; 確定 triggered the requests; the Review suggestion appeared and inserted; editing the chip preserved text |
| Hardware Shift+Return (P9) | With a hardware keyboard, press Return and Shift+Return in the composer | Return follows the Return Sends preference; Shift+Return inserts a newline; no draft loss | Recording | **blocked** — no hardware keyboard connected |
| Keyboard dismissal and insets (P9) | Open a session, focus the composer, dismiss interactively and via Done | Draft preserved; composer and transcript keep correct insets | Recording | **passed** — device multiline/Dynamic Type/dark-mode and search-keyboard journeys passed |
| VoiceOver reading order (P6–P11) | Enable VoiceOver; traverse Home, a session, Settings, model/agent pickers and suggestions | Logical order; every control has a name; switches announce state; chips/mentions announce meaning | Owner report and written order notes | **passed** — owner traversed all areas; no unnamed or out-of-order controls; switch state and focus restoration worked |
| Selection and scrolling (P8/P9) | Select text in a reply, copy, quote; scroll a long transcript; use Dynamic Type XXXL | Native handles work; quote reaches the composer; no dropped rows; following behaves | Recording with content synthetic | **passed** — copy/quote/selection, long transcript, jump-to-latest and Dynamic Type passed; AX XXXL truncates the Home header/path but rows remain usable |
| Memory pressure and device performance (P8–P11) | Long transcript (900+ rows), streaming run, open media, then trigger a memory warning in Instruments | Bounded caches trim; composer stays responsive; no jetsam | Instruments trace summary and measured frame times | **partial** — frame times, hitches and peak memory measured (DEVICE_VALIDATION.md); a real OS memory-pressure event was not produced |
| Production identifiers and signing (P12/P14) | Owner supplies bundle id, team, App Group and Keychain identity | Signed build launches; credentials persist across relaunch; no historical identifier copied | Build settings names only, no signing identity | **passed for development** — signed build launched and restored credentials; no production identifier/App Group/push entitlement added |
| Push notifications (P13 prerequisite) | Relay and credentials exist; feature off by default | No permission prompt until enabled; without relay the feature stays blocked/unverified | Recording and configuration inventory | **blocked** — feature not implemented/off; no relay or credentials |

## Checklist corrections

- **Initial setup scan:** the disconnected screen originally had no scanner; it now has a **Scan QR
  Code** action that reuses Settings' scanner and confirmation (D-109). The injected-scan device test
  verifies confirmation without redemption.
- **Return Sends** is a preference (default off). Plain Return sends only when it is enabled;
  Shift+Return always inserts a newline. The older wording that plain Return always sends is stale.
- The unreachable copy depends on the failure: a refused port shows “Couldn’t reach the OpenCode
  server.”; a blackholed host shows “The server didn’t answer in time.” Both carry the Local Network
  hint. Neither claims the OS denied permission.
- The haptic vocabulary is **eleven**, not a generic “all haptics”.
- The share sheet is a separate system process; `app.sheets` in XCUITest did not see it even while it
  was visibly presented. That is a test-visibility limitation, not a product failure.

## P11 simulator evidence is not device evidence

- The injected QR payloads in `SettingsUITests` prove parsing, confirmation and exactly-once
  forwarding through the same `PairingScannerClient` boundary. They do not prove AVFoundation
  capture, camera permission prompts or real QR decoding. The device run above does.
- The simulator settings/header journeys prove persistence and validation through the app's storage
  dependency. The device run exercised the signed app's Keychain and a real LAN header.
- The autocomplete latency trace (900 fixture entries, about 2.0 s including XCTest input) remains a
  simulator measurement; device frame and typing numbers are recorded separately in
  `DEVICE_VALIDATION.md`.
