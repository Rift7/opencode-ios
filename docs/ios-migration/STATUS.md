# iOS migration — status

## Baseline

| Item | Value |
| --- | --- |
| Integration branch | `ios` |
| Behaviour baseline | `7358160e808fb1870eeb20f5da8df832667019d1` (`origin/dev`) |
| `ios` head when P5 started | `5f143ea7927796f341d93373f002dfa2c1c38b7e` (PR #3, transport/retry/models/SSE/pairing) |
| P5 branch | `ios-shell`, created from `origin/ios` after `git fetch origin`; review corrections at `04da03cf` |
| Worktree | a separate worktree; the Android checkout and unrelated branches are untouched |

`git fetch origin` moved `origin/ios` from `d0fdf2f5` to `5f143ea7`. PR #3 is merged:
`mergedAt=2026-11-22T02:28:55Z`, merge commit `5f143ea7`, head `2326a49b`. The merged tree is
byte-identical to `2326a49b` (`git rev-parse origin/ios^{tree}` =
`git rev-parse 2326a49b^{tree}` = `0132311…`), so the corrected networking tree is present even
though the squash merge makes `2326a49b` not an ancestor.

## Phase status

| Phase | Scope | Status |
| --- | --- | --- |
| 1 | Read-only reconstruction audit | complete (`docs/ios-migration/audit/`) |
| 2 | `ios` branch, baseline, scaffold and gate | complete — `143d8f86` (PR #1) |
| 3 | Core: store, dependencies, sharing, tokens, logging, haptics | complete — `d0fdf2f5` (PR #2) |
| 4 | Server: transport, retry, models, SSE, pairing | complete — `5f143ea7` (PR #3, tree `2326a49b`) |
| 5 | App shell: launch, connection, pairing, reconnect | **complete on `ios-shell`**; draft PR: `Rift7/opencode-ios#4` |
| 6 | Home, drawer, projects, Catch Up, What's New | not started |
| 7 | Session, subagents, background work, request review | not started |
| 8 | Transcript | not started |
| 9 | Composer | not started |
| 10 | Media | not started |
| 11 | Settings, experiments, diagnostics, onboarding | not started |
| 12 | System integrations | not started |
| 13 | Voice (Experimental, off) | not started |
| 14 | Hardening | not started |

## Phase 5 — what landed

| Area | New or changed path | Gate |
| --- | --- | --- |
| Connection child reducer with identified state | `OpenCodeKit/Sources/OpenCodeApp/AppFeature.swift` (`ConnectionFeature`) | `ConnectionFeatureTests` — connect, auth, incompatible, malformed, offline, reconnect, overflow, lifecycle, stale attempt/stream tokens |
| App shell reducer: restore, form, pairing, persistence | same (`AppFeature`) | `AppFeatureTests` — restore outcomes, manual entry, pairing, persistence, disconnect, scene forwarding, unreadable-data recovery, multiple saved servers |
| Saved-data trust and explicit replacement | same (`SavedDataState`, `SavedDataWarningBanner`) | `AppFeatureTests` — temporary read failure, preserved list, replace confirmation/failure; UI tests from both storage-error screens |
| Attempt and stream identity | same (`ConnectionFeature.Token`) | `ConnectionFeatureTests` — delayed callbacks from cancelled work are ignored |
| Central connection eligibility | same (`canAttempt`, `startIfEligible`) | `ConnectionFeatureTests` — offline restore, background path return, foreground recovery |
| Address race over every candidate with a preferred head start | `OpenCodeKit/Sources/OpenCodeServer/Address/ServerLink.swift` | `ServerLinkTests` — first answer, 401 preference, head start, order |
| Stream lifecycle phases | `OpenCodeKit/Sources/OpenCodeServer/Events/EventStream.swift` (`EventStreamPhase`, `onPhase`) | `EventStreamPhaseTests` — connected/disconnected/ended, 401, overflow order |
| Client event seam with awaited phase callback | `OpenCodeKit/Sources/OpenCodeServer/Client/OpenCodeClient.swift` | `ConnectionFeatureTests`; `LocalFixtureServerTests.compatibleFixtureConnection` |
| Server keys and launch cache | `OpenCodeKit/Sources/OpenCodeServer/Address/ServerSharedKeys.swift` | `SharedStoreTests`; `AppFeatureTests` restore outcomes |
| SharedStore dependency and derived Keychain service | `OpenCodeKit/Sources/OpenCodeCore/Storage/SharedKeys.swift` | `SharedStoreTests`; app keychain probe |
| Network path observation | `OpenCodeKit/Sources/OpenCodeCore/Network/NetworkPathClient.swift`, `OpenCodeKit/Sources/OpenCodeServer/Retry/NetworkPathRetry.swift` | injected path in `ConnectionFeatureTests`; live monitor is device-only |
| Clipboard and UUID/date dependency names | `OpenCodeKit/Sources/OpenCodeCore/Dependencies/{PasteboardClient,FoundationClients}.swift` | dependency isolation; pairing tests |
| Launch scenarios, URL scheme and device probes | `OpenCodeKit/Sources/OpenCodeApp/AppLaunchConfiguration.swift`, `ios/OpenCode/Info.plist`, `ios/OpenCode/App/{OpenCodeApp,SavedServerProbe,UITestFixture}.swift` | 18 UI tests, including lifecycle fixture and Keychain restore probe |
| Connection UI and string catalog | `ios/OpenCode/App/RootView.swift`, `ios/OpenCode/Resources/Localizable.xcstrings` | child store scoped for observation; UI tests assert English copy |
| Screenshots | `docs/ios-migration/screens/p5-{disconnected,connected,failed-unreachable}[-dark].png` | simulator, fixture data only, light and dark |

## Adopted values and freshness (baseline `dev = 7358160e`)

| New behaviour | Android source | Last change | Treatment |
| --- | --- | --- | --- |
| Connection states `Idle/Pairing/Connecting/LoadingHome/Connected/Failed/Picking` | `app/AppFeature.kt` | current baseline | native phases `disconnected/connecting/loading/connected/reconnecting/failed`; `Picking` and Home loading are P6 |
| Address race, 3.5 s probe, preferred head start, 401 preference | `server/ServerLink.kt` | `5e4b4219`, 2026-11-16 | adopted as `ServerLink.probe`; health is one attempt per address |
| Saved server and saved list keys | `server/ServerSharedKeys.kt` | current baseline | adopted; Keychain-backed |
| Deep-link/paste pairing; parsing without redemption | `app/AppFeaturePairing.kt`, `server/OpenCodePairingLink.kt` | `5e4b4219`, 2026-11-16 | adopted; deep links require confirmation, paste is explicit |
| Local-network permission distinction | `server/LocalNetworkPermission.kt` | current baseline | **not adopted as a permission claim**: iOS has no equivalent preflight. Unreachable copy is generic; the local-network hint is a suggestion, never a denial classification |
| SSE lifecycle/backoff/overflow | `drawer/HomeConnectionFeature.kt`, `retry/NetworkRetry.kt` | current baseline | adopted in the P4 runner; P5 wires phases and REST refresh |
| Cached launch snapshot | `server/ServerSharedKeys.kt` (`cachedHomeSnapshots`) | current baseline | reduced to project summaries for the shell; Home snapshots arrive with P6 |
| Failure copy | `app/src/main/res/values/strings.xml` | current baseline | typed failure values in Swift; String Catalog at the app edge |

## Verified in this phase

| Command | Result |
| --- | --- |
| `swift test --package-path ios/OpenCodeKit` | **281 tests pass**: 161 server, 67 core, 53 app (live suite skipped without environment variables) |
| `ios/scripts/verify.sh` | toolchain 27.2 / Swift 6.4.2 / SDK 27.2; app build succeeds; `OpenCodeTests` passes; **18 UI tests pass**; package suites pass |
| Loopback compatible fixture | `LocalFixtureServerTests.compatibleFixtureConnection` serves `/api/info`, `/api/project`, `/api/event` over the real `URLSession` stack; health, projects and the handshake all arrive |
| Signed device build and install | with the existing local development identity (identifier not recorded): build, install and launch on the connected iPhone succeed |
| Device Keychain | `KeychainProbeTests` and `SavedServerProbeTests` pass on the device; the latter reads two fake servers through `AppRestoreResult` using a disposable service and removes them |
| Device lifecycle | `ConnectionLifecycleUITests` passes on the device with the deterministic in-app client: connected → Home → activate → connected |
| Screenshots | disconnected, connected and unreachable failure states captured in light and dark on the iPhone 18 Pro Max simulator with fixture-only data |

One `BoundedChannelTests.waiterHandoff` run failed on a timing-sensitive expectation during the first
`verify.sh`. The test sleeps 20 ms and assumes the consumer already took the first element. It was not
changed in P5; the failing run and later green runs are recorded, but the reruns do **not** establish
that the race is fixed or that P5 did not contribute to its timing. The cause remains unresolved.

## Not verified

- **A real V2 server on the device**: the device lifecycle check uses the in-app deterministic client,
  not a LAN server. Local-network prompts and a real socket's background/foreground restart remain
  unverified on hardware.
- **A real V2 server**: no build with the audited `/api/info` and `/api/project` routes was available.
  The P4 live build returns its web shell for those paths; P5 preserves `.incompatibleAPI` and does
  not remap routes. Fixture coverage is separate from live evidence. No P5 live connection succeeded
  against a real V2 server.
- **Camera QR pairing**: deferred; no scanner is implemented in P5. Paste and deep-link flows are
  implemented and tested.
- **Custom request headers** in the manual form: deferred. The model (`OpenCodeServer.headers`) and
  wire behaviour exist from P4; the form edits name/address/username/password only.
- **Home/session content**: the connected destination is intentionally a project list, not the P6
  drawer or P7 session screen.
- **Visual comparison with the original app**: unavailable; October screenshots are evidence, not a
  pixel target.

## Next

1. P6 (`ios-home`): HomeFeature, drawer, projects, Catch Up, and the cached Home snapshot replacing
   the P5 summary cache.
2. P6/P7: switch/forget/edit flows for saved servers, including the form's custom headers and the
   failure-report copy actions.
3. P8: transcript consumer and the off-screen event pressure policy (D-23).
