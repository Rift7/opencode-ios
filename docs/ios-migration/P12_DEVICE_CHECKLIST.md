# Phase 12 physical-iPhone checklist

Phase 12 owns executing these checks alongside its system-integration work. Nothing here was run
on a physical phone in P11: the phase used an iPhone simulator only. Every row starts **unverified**
and may become `passed`/`failed` only with the evidence named below.

Do not include a device identifier, signing identity, personal path, server address, pairing code,
credential, header value, message text or file content in an artifact. Synthetic fixtures may be
used; redact anything else.

## Prerequisites

- Xcode 27.2 and an iOS 27.2 iPhone. Signing is owner-supplied; the migration does not copy a team
  or provisioning profile.
- A compatible V2 server for catalog/network checks, or the synthetic loopback/session-lab fixtures
  where the row allows them.
- System Haptics on for haptic checks.
- A second device or a desktop showing a QR code for the camera check.

## Checklist

| Feature and prerequisite | Synthetic setup and reproducible steps | Expected result | Evidence to capture | Status |
| --- | --- | --- | --- | --- |
| Haptic vocabulary (P3) | Launch the debug app with `-hapticProbe`; play each named haptic from the probe | Each of the eleven haptics is felt and distinguishable; tap is lighter than warning/error | Probe classification line and a written feel comparison; no device id | unverified, deferred to P12 |
| Local-network denial (P5) | Install debug build; connect to a LAN fixture; deny the Local Network prompt | No fixture request arrives; the app shows the generic unreachable copy and the Local Network hint, never a false denial claim | Screen recording of prompt + result; request count from the fixture | unverified, deferred to P12 |
| Local-network allow (P5) | Repeat and allow the prompt | Fixture request arrives; Home loads | Fixture request log (address redacted) and screenshot | unverified, deferred to P12 |
| Real-socket foreground/background recovery (P5) | Connect to a fixture; background the app, change the network, foreground it | The single shell stream reconnects; Home re-reads REST; no duplicate stream | Fixture connection count and screen recording | unverified, deferred to P12 |
| Camera permission denied (P11) | Settings → Scan QR Code; deny camera access | Typed denied state, no crash, paste alternative remains available | Screenshot of typed state; Settings privacy page | unverified, deferred to P12 |
| Camera restricted/unavailable (P11) | Use a device with camera restriction or no camera | Typed restricted/unavailable state; no redemption | Screenshot and classification | unverified, deferred to P12 |
| QR scan and confirmation (P11) | Run `opencode pair --remote`; scan the QR; confirm Pair | Confirmation appears before redemption; the code is redeemed exactly once; duplicate frames do not redeem again | Screen recording from scan through connected Home; server pairing log with code redacted | unverified, deferred to P12 |
| Expired/used pairing code (P11) | Scan a code twice or wait for expiry | Typed expired/unsupported message; no credentials saved | Screenshot and redacted server log | unverified, deferred to P12 |
| Header persistence and Keychain (P11) | Save a synthetic proxy header; relaunch; inspect Server Details; then simulate denied Keychain in a signed build | Header persists and is sent only to the server origin; a failed write keeps the old server usable | Keychain probe classification, request header names only (values redacted) | unverified, deferred to P12 |
| Photo/file permission and provider eviction (P10) | Pick a photo and a file; revoke Photos/Files access; evict the provider; reopen the draft | Failed import is typed; staged files remain owned; no picker URL is persisted | Screen recording and draft probe; no file contents | unverified, deferred to P12 |
| Playback interruption (P10) | Play a video/audio attachment; take a call or unplug headphones | Playback pauses/resumes per system audio rules; the viewer stays stable | Screen recording | unverified, deferred to P12 |
| Share presentation (P10) | Share shell output and an opened file | Native share sheet presents; no credential in the payload | Screen recording with content redacted | unverified, deferred to P12 |
| IME marked text and suggestions (P9/P11) | Compose in a CJK IME; type `@`, keep composition open; commit; then edit the chip | Suggestions do not query/commit during marked text; no text typed after the query is overwritten | Screen recording and typed draft | unverified, deferred to P12 |
| Hardware Shift+Return (P9) | With a hardware keyboard, press Return and Shift+Return in the composer | Return sends; Shift+Return inserts a newline; no draft loss | Screen recording | unverified, deferred to P12 |
| Keyboard dismissal and insets (P9) | Open a session, focus the composer, dismiss interactively and via Done | Draft preserved; composer and transcript keep correct insets | Screen recording | unverified, deferred to P12 |
| VoiceOver reading order (P6–P11) | Enable VoiceOver; traverse Home, a session, Settings, model/agent pickers and suggestions | Logical order; every control has a name; switches announce state; chips/mentions announce meaning | VoiceOver screen recording and a written order table | unverified, deferred to P12 |
| Selection and scrolling (P8/P9) | Select text in a reply, copy, quote; scroll a long transcript; use Dynamic Type XXXL | Native handles work; quote reaches the composer; no dropped rows; following behaves | Screen recording with content synthetic | unverified, deferred to P12 |
| Memory pressure and device performance (P8–P11) | Long transcript (900+ rows), streaming run, open media, then trigger a memory warning in Instruments | Bounded caches trim; composer stays responsive; no jetsam | Instruments trace summary (no personal data) and measured frame times | unverified, deferred to P12 |
| Production identifiers and signing (P12/P14) | Owner supplies bundle id, team, App Group and Keychain identity | Signed build launches; credentials persist across relaunch; no historical identifier copied | Build settings names only, no signing identity | unverified, deferred to P12 |
| Push notifications (P13 prerequisite) | Relay and credentials exist; feature off by default | No permission prompt until enabled; without relay the feature stays blocked/unverified | Screen recording and configuration inventory | unverified, deferred to P12/P13 |

## P11 simulator evidence is not device evidence

- The injected QR payloads in `SettingsUITests` prove parsing, confirmation and exactly-once
  forwarding through the same `PairingScannerClient` boundary. They do not prove AVFoundation
  capture, camera permission prompts or real QR decoding.
- The simulator settings/header journeys prove persistence and validation through the app's storage
  dependency. They do not prove a signed build's Keychain entitlement or hardware secure storage.
- The autocomplete latency trace (900 fixture entries, about 2.0 s from UI-test typing through the
  first suggestion, including XCTest input overhead) is a simulator measurement, not a
  device-performance claim.
