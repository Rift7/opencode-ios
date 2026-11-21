# BRANCHES — every branch audited, with disposition

Audit time **2026-11-21T18:28:04Z**. Default branch `dev` = `7358160e808fb1870eeb20f5da8df832667019d1`.
Mirror at `<audit-directory>/mirror.git`.
Machine-readable form: `branches.json` (same folder).

**157 heads including `dev`; 156 audited below (dev is the baseline).** Method: full `--mirror` clone, then
`git for-each-ref refs/heads` (unrestricted listing), then per branch `merge-base`, `rev-list --left-right --count`,
`git cherry` (patch equivalence), `diff --name-only` against the merge base, and manual reading of every
divergent branch's commits and touched code/tests. Categories are computed, dispositions are judged.

Disposition vocabulary: **integrated** (behaviour already in dev), **adopt** (worth landing as-is),
**adapt** (behaviour worth keeping, implementation must change), **defer** (blocked or low value now),
**exclude** (do not use), **empty** (no net change), **reference only** (unrelated history kept as evidence).

## Summary

| Category | Count |
| --- | --- |
| integrated (ancestor of dev) | 124 |
| divergent with unique commits | 25 |
| unnamed patch-equivalent / already-integrated (non-ancestor) | 1 (`proto-send-native`) |
| empty diff | 2 (`port-toolbounds`, `strings-xml-migration`) |
| unrelated history | 4 (glass stack + webrtc) |

Deduplication (verified by commit containment, not names):

- **Glass family** — `glass-perf` ⊂ `glass-lens-candidate` ⊂ `glass-look` ⊂ `webrtc-spike`. One line of
  pre-rewrite history; `webrtc-spike` is the tip (353 commits). Treated as a single evidence set.
- **Background runs** — `background-run-connection` ⊂ `background-run-notices` ⊂ `background-run-replies`
  (shared merge base `d217e048`; tips are "Merge dev" commits). One feature, take the tip.
- **Play crashes** — `play-crashes` ⊂ `play-crashes-ci`.
- **Parity staging** — `sync/*`, `port-*`, `sync/main-into-dev` are all ancestors of dev: superseded staging
  branches whose content landed by another route.

## Every branch

| Branch | Head | Category | Ahead/Behind | Unique | Paths | Disposition | iOS migration relevance |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `glass-lens-candidate` | `74436b3f` | unrelated-history | — | — | — | exclude (reference only) | evidence |
| `glass-look` | `8283379f` | unrelated-history | — | — | — | exclude (reference only) | evidence |
| `glass-perf` | `b7bc730f` | unrelated-history | — | — | — | exclude (reference only) | evidence |
| `webrtc-spike` | `90f30f25` | unrelated-history | — | — | — | exclude (reference only) | evidence |
| `agent-widgets` | `c9df2092` | divergent | 36/33 | 36 | 113 | defer | low |
| `ui/material-native` | `dfa0531a` | divergent | 18/468 | 18 | 76 | exclude | none |
| `ios-sync-911ab132` | `d1fe64d5` | divergent | 8/237 | 8 | 45 | exclude (already integrated) | none |
| `background-run-replies` | `68c98760` | divergent | 6/13 | 6 | 198 | adapt (behaviour only) | medium |
| `android/debug-launcher-identity` | `666d2e7a` | divergent | 4/277 | 4 | 3 | exclude (already integrated) | none |
| `background-run-notices` | `a38747ba` | divergent | 4/13 | 4 | 140 | adapt (behaviour only) | medium |
| `feat/assistant` | `6bbf6321` | divergent | 4/13 | 4 | 88 | exclude | none |
| `ci-sdk-platform-37-1` | `fc3c3b52` | divergent | 3/1 | 3 | 6 | adopt (Android CI) | none |
| `compose-bom-2026-11` | `2bd00882` | divergent | 3/1 | 3 | 4 | exclude (already integrated) | none |
| `background-run-connection` | `92c6d203` | divergent | 2/13 | 2 | 136 | adapt (behaviour only) | low |
| `jump-previous-message` | `a509d3e0` | divergent | 2/13 | 2 | 66 | defer (Android-only) | low |
| `media-cache-limit` | `50dc78ca` | divergent | 2/32 | 2 | 3 | adopt (Android) | none |
| `okhttp-idn-keep` | `bf22d486` | divergent | 2/5 | 2 | 2 | adopt (Android release) | none |
| `play-crashes-ci` | `f9ace719` | divergent | 2/6 | 2 | 3 | defer | none |
| `raise-to-talk-motion` | `c4393639` | divergent | 2/32 | 2 | 3 | adopt (Android) | none |
| `skip-encoding-in-memory-keys` | `55c76e6d` | divergent | 2/6 | 2 | 5 | adopt (Android) | none |
| `transcript/triple-tap-paragraph` | `670abff2` | divergent | 2/166 | 2 | 7 | adapt (Android) | low |
| `docs-open-from-trigger` | `989664d4` | divergent | 1/38 | 1 | 1 | adopt (docs) | none |
| `feat/assist-default-assistant` | `4076c504` | divergent | 1/350 | 1 | 2 | exclude | none |
| `feat/scroll-frame-diagnostics` | `ec005c75` | divergent | 1/221 | 1 | 10 | defer | none |
| `fix-send-flight-landing` | `fe78fbd4` | divergent | 1/277 | 1 | 7 | exclude (superseded) | none |
| `pill-row-exit` | `4eabe2a6` | divergent | 1/149 | 1 | 1 | adopt (Android, adapt) | low |
| `play-crashes` | `bebb140b` | divergent | 1/6 | 1 | 2 | adopt (Android tooling) | none |
| `session-switch-transition` | `1644438d` | divergent | 1/149 | 1 | 4 | exclude (policy) | none |
| `ui/settings-chevron` | `53479627` | divergent | 1/331 | 1 | 5 | defer (design decision) | none |
| `port-toolbounds` | `38498f43` | empty-diff | 1/191 | 1 | 0 | empty | none |
| `proto-send-native` | `efa82a22` | patch-equivalent | 1/244 | 1 | 78 | exclude (already integrated) | reference |
| `strings-xml-migration` | `c5dd998d` | empty-diff | 1/250 | 1 | 0 | empty | none |
| `agent-chip-roll` | `5cfa8add` | integrated-ancestor | 0/148 | 0 | 0 | integrated | none |
| `android-qa-fixes` | `58a85367` | integrated-ancestor | 0/508 | 0 | 0 | integrated | none |
| `android/fullscreen-drawing` | `01aaad60` | integrated-ancestor | 0/217 | 0 | 0 | integrated | none |
| `android/unified-fullscreen` | `d29e6ed8` | integrated-ancestor | 0/213 | 0 | 0 | integrated | none |
| `android/unified-visual-media` | `72e5aadb` | integrated-ancestor | 0/206 | 0 | 0 | integrated | none |
| `answer-bar-button-motion` | `8161c5f1` | integrated-ancestor | 0/148 | 0 | 0 | integrated | none |
| `archive-ignored-error` | `8566441f` | integrated-ancestor | 0/126 | 0 | 0 | integrated | none |
| `archived-page` | `86d2d0bd` | integrated-ancestor | 0/281 | 0 | 0 | integrated | none |
| `autocomplete-native` | `ba44e669` | integrated-ancestor | 0/99 | 0 | 0 | integrated | none |
| `background-subagents` | `747f4b73` | integrated-ancestor | 0/349 | 0 | 0 | integrated | none |
| `background-work-trace` | `b0402f86` | integrated-ancestor | 0/122 | 0 | 0 | integrated | none |
| `brand/desktop-restyle` | `cfecef6c` | integrated-ancestor | 0/425 | 0 | 0 | integrated | none |
| `button-press-scale` | `b5242d7b` | integrated-ancestor | 0/148 | 0 | 0 | integrated | none |
| `call-card-presence` | `68a836ce` | integrated-ancestor | 0/92 | 0 | 0 | integrated | none |
| `chore-comment-history` | `18280423` | integrated-ancestor | 0/224 | 0 | 0 | integrated | none |
| `chore-trim-comments` | `0bff99c7` | integrated-ancestor | 0/241 | 0 | 0 | integrated | none |
| `ci-flakes` | `68d0c2e4` | integrated-ancestor | 0/480 | 0 | 0 | integrated | none |
| `ci-mirror` | `43ead52f` | integrated-ancestor | 0/478 | 0 | 0 | integrated | none |
| `ci/dev-branch` | `14aeadd4` | integrated-ancestor | 0/349 | 0 | 0 | integrated | none |
| `ci/play-wait-for-review` | `734d9ddf` | integrated-ancestor | 0/309 | 0 | 0 | integrated | none |
| `ci/release-guard` | `8442633f` | integrated-ancestor | 0/419 | 0 | 0 | integrated | none |
| `coil-image-loading` | `8e4d7b9f` | integrated-ancestor | 0/97 | 0 | 0 | integrated | none |
| `composer-session-orphans` | `73fba198` | integrated-ancestor | 0/71 | 0 | 0 | integrated | none |
| `composer-text-input-native` | `39bc3c8b` | integrated-ancestor | 0/97 | 0 | 0 | integrated | none |
| `composer-trailing-motion` | `c08f41a8` | integrated-ancestor | 0/152 | 0 | 0 | integrated | none |
| `connection-pill-swap` | `f6087f6c` | integrated-ancestor | 0/148 | 0 | 0 | integrated | none |
| `core-orphans` | `583487e7` | integrated-ancestor | 0/71 | 0 | 0 | integrated | none |
| `docs-comment-rules` | `275da0c1` | integrated-ancestor | 0/274 | 0 | 0 | integrated | none |
| `docs/drop-ryan-gate` | `f5e2afad` | integrated-ancestor | 0/347 | 0 | 0 | integrated | none |
| `drawer-card-leftovers` | `b054a3a8` | integrated-ancestor | 0/122 | 0 | 0 | integrated | none |
| `drawer-hscroll` | `4f07aebc` | integrated-ancestor | 0/488 | 0 | 0 | integrated | none |
| `drawer-orphans` | `5d8a3556` | integrated-ancestor | 0/71 | 0 | 0 | integrated | none |
| `drawer-pan-leftovers` | `1990689e` | integrated-ancestor | 0/97 | 0 | 0 | integrated | none |
| `drawer-selection` | `87378f6f` | integrated-ancestor | 0/285 | 0 | 0 | integrated | none |
| `drawer-shortcut-rows-native` | `b5668608` | integrated-ancestor | 0/116 | 0 | 0 | integrated | none |
| `emu-setup` | `94c0123c` | integrated-ancestor | 0/153 | 0 | 0 | integrated | none |
| `error-notice` | `740e4811` | integrated-ancestor | 0/98 | 0 | 0 | integrated | none |
| `feat-agent-default` | `dd6ff0e0` | integrated-ancestor | 0/163 | 0 | 0 | integrated | none |
| `feat-composer-quote` | `a2e77d9e` | integrated-ancestor | 0/159 | 0 | 0 | integrated | none |
| `feat-language-setting` | `965b1348` | integrated-ancestor | 0/227 | 0 | 0 | integrated | none |
| `feat-viewer-chrome` | `d3d17956` | integrated-ancestor | 0/171 | 0 | 0 | integrated | none |
| `feat-viewer-motion` | `017632f8` | integrated-ancestor | 0/169 | 0 | 0 | integrated | none |
| `feedback-sounds-notifications` | `4bf4afea` | integrated-ancestor | 0/489 | 0 | 0 | integrated | none |
| `fix-agent-picker` | `70897f81` | integrated-ancestor | 0/180 | 0 | 0 | integrated | none |
| `fix-family-test-flake` | `eed892a9` | integrated-ancestor | 0/297 | 0 | 0 | integrated | none |
| `fix-file-card-check` | `5214bc9f` | integrated-ancestor | 0/175 | 0 | 0 | integrated | none |
| `fix-markup-handoff` | `38c9f10e` | integrated-ancestor | 0/178 | 0 | 0 | integrated | none |
| `fix-question-ux` | `f322fc74` | integrated-ancestor | 0/274 | 0 | 0 | integrated | none |
| `fix-selection-opens-drawer` | `8692c4a5` | integrated-ancestor | 0/278 | 0 | 0 | integrated | none |
| `fix-viewer-pen` | `25f8828f` | integrated-ancestor | 0/176 | 0 | 0 | integrated | none |
| `fix/composer-bottom-gap` | `e5294f85` | integrated-ancestor | 0/334 | 0 | 0 | integrated | none |
| `fix/floating-call-ux` | `bd1d9a03` | integrated-ancestor | 0/337 | 0 | 0 | integrated | none |
| `fix/local-network-permission` | `16962e98` | integrated-ancestor | 0/330 | 0 | 0 | integrated | none |
| `fix/pairing-qr` | `b53a64fb` | integrated-ancestor | 0/342 | 0 | 0 | integrated | none |
| `fix/session-streaming-prefix` | `2376bb73` | integrated-ancestor | 0/301 | 0 | 0 | integrated | none |
| `fix/show-more-black-box` | `3fde91be` | integrated-ancestor | 0/408 | 0 | 0 | integrated | none |
| `fix/table-swipe-drawer` | `32882d2c` | integrated-ancestor | 0/408 | 0 | 0 | integrated | none |
| `fix/voice-speaks-as-the-session` | `4fa47dff` | integrated-ancestor | 0/237 | 0 | 0 | integrated | none |
| `fix/voice-toggle` | `4dbfefda` | integrated-ancestor | 0/361 | 0 | 0 | integrated | none |
| `image-load-fade` | `d6aabfd6` | integrated-ancestor | 0/148 | 0 | 0 | integrated | none |
| `inbox-archived` | `d083bb6c` | integrated-ancestor | 0/298 | 0 | 0 | integrated | none |
| `inbox-row-menu` | `8c89bf2a` | integrated-ancestor | 0/299 | 0 | 0 | integrated | none |
| `min-sdk` | `a5237b2f` | integrated-ancestor | 0/473 | 0 | 0 | integrated | none |
| `min-sdk-33` | `d9522ec8` | integrated-ancestor | 0/410 | 0 | 0 | integrated | none |
| `motion-rules` | `b01fa973` | integrated-ancestor | 0/61 | 0 | 0 | integrated | none |
| `onboarding-fixes` | `9c2ba6f7` | integrated-ancestor | 0/499 | 0 | 0 | integrated | none |
| `orphan-sweep` | `65a1b397` | integrated-ancestor | 0/86 | 0 | 0 | integrated | none |
| `page-stack-native` | `31b642a4` | integrated-ancestor | 0/122 | 0 | 0 | integrated | none |
| `pairing-feedback` | `c6d391a7` | integrated-ancestor | 0/488 | 0 | 0 | integrated | none |
| `play-draft-fallback` | `94dc0b1b` | integrated-ancestor | 0/689 | 0 | 0 | integrated | none |
| `play-open-testing` | `2e56ec4d` | integrated-ancestor | 0/715 | 0 | 0 | integrated | none |
| `play-photo-picker` | `6ec53599` | integrated-ancestor | 0/695 | 0 | 0 | integrated | none |
| `polish/overscroll` | `57bb4f07` | integrated-ancestor | 0/330 | 0 | 0 | integrated | none |
| `polish/pr8-fixes` | `85666eda` | integrated-ancestor | 0/356 | 0 | 0 | integrated | none |
| `port-captions` | `f0c57c78` | integrated-ancestor | 0/220 | 0 | 0 | integrated | none |
| `port-catalog` | `8233821d` | integrated-ancestor | 0/220 | 0 | 0 | integrated | none |
| `port-drafts` | `d9dd8ca6` | integrated-ancestor | 0/202 | 0 | 0 | integrated | none |
| `port-mdimages` | `53d746c4` | integrated-ancestor | 0/194 | 0 | 0 | integrated | none |
| `port-pairing-name` | `5e4b4219` | integrated-ancestor | 0/165 | 0 | 0 | integrated | none |
| `port-polling` | `3000bded` | integrated-ancestor | 0/184 | 0 | 0 | integrated | none |
| `port-raise` | `e40dad58` | integrated-ancestor | 0/186 | 0 | 0 | integrated | none |
| `port-reasoning` | `a11abb50` | integrated-ancestor | 0/191 | 0 | 0 | integrated | none |
| `port-recents` | `340bba84` | integrated-ancestor | 0/220 | 0 | 0 | integrated | none |
| `port-requests` | `211231ab` | integrated-ancestor | 0/196 | 0 | 0 | integrated | none |
| `port-warmup` | `ff8e1611` | integrated-ancestor | 0/190 | 0 | 0 | integrated | none |
| `production` | `c615a2cb` | integrated-ancestor | 0/60 | 0 | 0 | integrated | none |
| `qr-scanner-fixes` | `0cf1240d` | integrated-ancestor | 0/498 | 0 | 0 | integrated | none |
| `quote-comment-covers` | `afdfc4db` | integrated-ancestor | 0/69 | 0 | 0 | integrated | none |
| `reload-models-on-update` | `5ce0e28f` | integrated-ancestor | 0/239 | 0 | 0 | integrated | none |
| `remove-flight-geometry` | `775d41c5` | integrated-ancestor | 0/97 | 0 | 0 | integrated | none |
| `remove-motion-audit` | `24c96b93` | integrated-ancestor | 0/122 | 0 | 0 | integrated | none |
| `remove-photo-sheet` | `085a3955` | integrated-ancestor | 0/122 | 0 | 0 | integrated | none |
| `request-panel-leave` | `88b3b83c` | integrated-ancestor | 0/148 | 0 | 0 | integrated | none |
| `scheduled-release` | `4daa54d5` | integrated-ancestor | 0/506 | 0 | 0 | integrated | none |
| `security-caller-checks` | `02df32c6` | integrated-ancestor | 0/501 | 0 | 0 | integrated | none |
| `selection-checkmark-motion` | `52c72ce1` | integrated-ancestor | 0/148 | 0 | 0 | integrated | none |
| `server-address-links` | `55fae672` | integrated-ancestor | 0/167 | 0 | 0 | integrated | none |
| `settings-rows-motion` | `4b47f27f` | integrated-ancestor | 0/148 | 0 | 0 | integrated | none |
| `shared-location-animated-visibility` | `8c4dbea9` | integrated-ancestor | 0/91 | 0 | 0 | integrated | none |
| `simplify/pr21` | `0134a31a` | integrated-ancestor | 0/315 | 0 | 0 | integrated | none |
| `simplify/pr26` | `e136e64e` | integrated-ancestor | 0/325 | 0 | 0 | integrated | none |
| `simplify/pr28` | `15b310c2` | integrated-ancestor | 0/330 | 0 | 0 | integrated | none |
| `simplify/pr34` | `30bcd3b8` | integrated-ancestor | 0/330 | 0 | 0 | integrated | none |
| `simplify/pr37` | `7cd464b3` | integrated-ancestor | 0/330 | 0 | 0 | integrated | none |
| `splash-day-night` | `16935a8f` | integrated-ancestor | 0/148 | 0 | 0 | integrated | none |
| `strings-outside-composables` | `b019bf60` | integrated-ancestor | 0/250 | 0 | 0 | integrated | none |
| `sync/ios` | `0fb2ed4b` | integrated-ancestor | 0/719 | 0 | 0 | integrated | none |
| `sync/ios-3d50fd74` | `c69fa436` | integrated-ancestor | 0/363 | 0 | 0 | integrated | none |
| `sync/ios-dccec82e` | `34cdb92c` | integrated-ancestor | 0/699 | 0 | 0 | integrated | none |
| `sync/main-into-dev` | `635f4739` | integrated-ancestor | 0/311 | 0 | 0 | integrated | none |
| `tool-group-chevron-rotate` | `1a092ff8` | integrated-ancestor | 0/148 | 0 | 0 | integrated | none |
| `touch-recovery-owners` | `db619ce3` | integrated-ancestor | 0/97 | 0 | 0 | integrated | none |
| `transcript-fades-native` | `f67c0257` | integrated-ancestor | 0/97 | 0 | 0 | integrated | none |
| `transcript-reveal-styles` | `1e4de667` | integrated-ancestor | 0/97 | 0 | 0 | integrated | none |
| `translations` | `0dab52c0` | integrated-ancestor | 0/229 | 0 | 0 | integrated | none |
| `ui-brand-prototype` | `a9794d9d` | integrated-ancestor | 0/455 | 0 | 0 | integrated | none |
| `ui/settings-desktop-accents` | `80ba8918` | integrated-ancestor | 0/360 | 0 | 0 | integrated | none |
| `ui/settings-rows` | `0579e80b` | integrated-ancestor | 0/308 | 0 | 0 | integrated | none |
| `unsent-sessions` | `8582e0ae` | integrated-ancestor | 0/121 | 0 | 0 | integrated | none |
| `unused-libraries` | `d7b19a9a` | integrated-ancestor | 0/122 | 0 | 0 | integrated | none |
| `unused-motion-tunables` | `4f9ff988` | integrated-ancestor | 0/118 | 0 | 0 | integrated | none |
| `viewer-chrome-close` | `37570208` | integrated-ancestor | 0/148 | 0 | 0 | integrated | none |
| `voice-crash` | `8ef562ff` | integrated-ancestor | 0/414 | 0 | 0 | integrated | none |
| `windows-file-mentions` | `f5b1abee` | integrated-ancestor | 0/92 | 0 | 0 | integrated | none |

## Detail for non-integrated branches

### `glass-lens-candidate` — `74436b3f` — exclude (reference only)

- Tip: 2026-10-08T10:10:04+05:30 — chore(glass): frosted and lens glass candidates behind -lab-glass
- Category: unrelated-history; ahead/behind `—`; unique commits —; changed paths —; areas: -
- Merge base: `none`
- **Disposition:** exclude (reference only) — Unrelated history; lens-glass experiments + docs. Superseded by glass-look.
- **iOS migration relevance:** evidence

### `glass-look` — `8283379f` — exclude (reference only)

- Tip: 2026-10-08T10:39:11+05:30 — docs(port): record why the frosted glass beat the lens
- Category: unrelated-history; ahead/behind `—`; unique commits —; changed paths —; areas: -
- Merge base: `none`
- **Disposition:** exclude (reference only) — Newest docs/port set for d809b1e incl. deviations.md and glass perf report. Source of the extracted dossier.
- **iOS migration relevance:** evidence

### `glass-perf` — `b7bc730f` — exclude (reference only)

- Tip: 2026-10-08T08:53:54+05:30 — chore(glass): measure the glass blur on the host GPU emulator
- Category: unrelated-history; ahead/behind `—`; unique commits —; changed paths —; areas: -
- Merge base: `none`
- **Disposition:** exclude (reference only) — Oldest unrelated-history snapshot (iOS 553a407 era); 101 docs/port files, 78 reference images. Kept for the dossier only.
- **iOS migration relevance:** evidence

### `webrtc-spike` — `90f30f25` — exclude (reference only)

- Tip: 2026-10-08T10:42:34+05:30 — chore(spike): prove app-owned voice audio over LiveKit's libwebrtc
- Category: unrelated-history; ahead/behind `—`; unique commits —; changed paths —; areas: -
- Merge base: `none`
- **Disposition:** exclude (reference only) — Unrelated history; newest reference images (iOS 16b40f7) + WebRTC loopback spike. Evidence only.
- **iOS migration relevance:** evidence

### `agent-widgets` — `c9df2092` — defer

- Tip: 2026-11-21T13:07:00+01:00 — fix(widgets): canvas alpha sets the opacity instead of multiplying
- Category: divergent; ahead/behind `36/33`; unique commits 36; changed paths 113; areas: .gitignore, AGENTS.md, core, docs, feature, gradle, scripts, server
- Merge base: `ceaa16a9`
- **Disposition:** defer — In-app agent-generated UI renderer (not a home-screen widget); ported *from* an iOS branch that is not in this repo. Needs server plugin + native runtime.
- **iOS migration relevance:** low

### `ui/material-native` — `dfa0531a` — exclude

- Tip: 2026-11-09T09:30:58-05:00 — fix(composer): the agent and model chips drop their outline
- Category: divergent; ahead/behind `18/468`; unique commits 18; changed paths 76; areas: app, core, docs, feature, scripts
- Merge base: `289a7895`
- **Disposition:** exclude — 468 behind; an M3 restyle that contradicts the current desktop design system. 72 overlapping paths.
- **iOS migration relevance:** none

### `ios-sync-911ab132` — `d1fe64d5` — exclude (already integrated)

- Tip: 2026-11-14T21:29:03-05:00 — Settled and covered sessions stop polling
- Category: divergent; ahead/behind `8/237`; unique commits 8; changed paths 45; areas: docs, feature, server
- Merge base: `a59a8c65`
- **Disposition:** exclude (already integrated) — All 8 ports landed in dev as #84–#91; branch differs only by comments dev forbids.
- **iOS migration relevance:** none

### `background-run-replies` — `68c98760` — adapt (behaviour only)

- Tip: 2026-11-20T21:12:42-05:00 — Merge dev into background-run-replies
- Category: divergent; ahead/behind `6/13`; unique commits 6; changed paths 198; areas: app, core, docs, feature
- Merge base: `d217e048`
- **Disposition:** adapt (behaviour only) — Stack tip (includes notices+connection). FGS/Doze machinery is Android-only; notification reply and away-baseline semantics are worth matching on iOS.
- **iOS migration relevance:** medium

### `android/debug-launcher-identity` — `666d2e7a` — exclude (already integrated)

- Tip: 2026-11-13T17:34:37+01:00 — Extend the blueprint beyond the Android mask without resizing the mark
- Category: divergent; ahead/behind `4/277`; unique commits 4; changed paths 3; areas: app
- Merge base: `5247be11`
- **Disposition:** exclude (already integrated) — Blob-identical to dev b33c70e8; dev has a later lint fix the branch would undo.
- **iOS migration relevance:** none

### `background-run-notices` — `a38747ba` — adapt (behaviour only)

- Tip: 2026-11-20T21:12:33-05:00 — Merge dev into background-run-notices
- Category: divergent; ahead/behind `4/13`; unique commits 4; changed paths 140; areas: app, core, docs, feature
- Merge base: `d217e048`
- **Disposition:** adapt (behaviour only) — Needs-you / finished notices with a visible-baseline; iOS gets this via APNs relay.
- **iOS migration relevance:** medium

### `feat/assistant` — `6bbf6321` — exclude

- Tip: 2026-11-20T21:29:42-05:00 — Fix review findings in the assistant's phone tools
- Category: divergent; ahead/behind `4/13`; unique commits 4; changed paths 88; areas: app, core, docs, feature, scripts, server
- Merge base: `d217e048`
- **Disposition:** exclude — Reverted in dev (bc68c787). Android-only side-button assistant; iOS cannot replace Siri.
- **iOS migration relevance:** none

### `ci-sdk-platform-37-1` — `fc3c3b52` — adopt (Android CI)

- Tip: 2026-11-21T12:17:40-05:00 — ci: install SDK platform 37.1
- Category: divergent; ahead/behind `3/1`; unique commits 3; changed paths 6; areas: .github, build-logic, feature, gradle
- Merge base: `1380772d`
- **Disposition:** adopt (Android CI) — Only unique hunk: install platforms;android-37.1 in ci.yml/release.yml. Needs .github review.
- **iOS migration relevance:** none

### `compose-bom-2026-11` — `2bd00882` — exclude (already integrated)

- Tip: 2026-11-21T12:38:19-05:00 — chore(deps): let the Compose BOM set Material 3
- Category: divergent; ahead/behind `3/1`; unique commits 3; changed paths 4; areas: build-logic, feature, gradle
- Merge base: `1380772d`
- **Disposition:** exclude (already integrated) — Squashed as dev 7358160e.
- **iOS migration relevance:** none

### `background-run-connection` — `92c6d203` — adapt (behaviour only)

- Tip: 2026-11-20T21:12:25-05:00 — Merge dev into background-run-connection
- Category: divergent; ahead/behind `2/13`; unique commits 2; changed paths 136; areas: app, core, docs, feature
- Merge base: `d217e048`
- **Disposition:** adapt (behaviour only) — dataSync FGS; iOS has no equivalent and must not copy it.
- **iOS migration relevance:** low

### `jump-previous-message` — `a509d3e0` — defer (Android-only)

- Tip: 2026-11-20T21:12:52-05:00 — Merge dev into jump-previous-message
- Category: divergent; ahead/behind `2/13`; unique commits 2; changed paths 66; areas: docs, feature
- Merge base: `d217e048`
- **Disposition:** defer (Android-only) — Up-arrow to previous user message; no iOS counterpart recovered. No tests.
- **iOS migration relevance:** low

### `media-cache-limit` — `50dc78ca` — adopt (Android)

- Tip: 2026-11-20T18:24:29-05:00 — fix(media): trim only finished blobs, off the main thread
- Category: divergent; ahead/behind `2/32`; unique commits 2; changed paths 3; areas: docs, feature
- Merge base: `4c1e0054`
- **Disposition:** adopt (Android) — Caps media-reference disk cache at 256 MiB; iOS already does this. Fixes unbounded growth.
- **iOS migration relevance:** none

### `okhttp-idn-keep` — `bf22d486` — adopt (Android release)

- Tip: 2026-11-21T00:58:02-05:00 — chore(app): word the IDN keep rule comment as a workaround
- Category: divergent; ahead/behind `2/5`; unique commits 2; changed paths 2; areas: app
- Merge base: `71c09d35`
- **Disposition:** adopt (Android release) — R8 keep rule for OkHttp IDN; release-crash mitigation.
- **iOS migration relevance:** none

### `play-crashes-ci` — `f9ace719` — defer

- Tip: 2026-11-20T23:12:37-05:00 — ci: open issues for Google Play crashes once a day
- Category: divergent; ahead/behind `2/6`; unique commits 2; changed paths 3; areas: .github, docs, scripts
- Merge base: `c001a08f`
- **Disposition:** defer — Scheduled workflow depends on an AWS role/secret that does not exist.
- **iOS migration relevance:** none

### `raise-to-talk-motion` — `c4393639` — adopt (Android)

- Tip: 2026-11-20T18:33:56-05:00 — fix(voice): read a late first motion sample after a cover
- Category: divergent; ahead/behind `2/32`; unique commits 2; changed paths 3; areas: docs, feature
- Merge base: `4c1e0054`
- **Disposition:** adopt (Android) — Registers motion only while deciding a raise; iOS 7393e966 already has it.
- **iOS migration relevance:** none

### `skip-encoding-in-memory-keys` — `55c76e6d` — adopt (Android)

- Tip: 2026-11-21T00:15:53-05:00 — fix(drawer): flush the transcript cache off the main thread on pause
- Category: divergent; ahead/behind `2/6`; unique commits 2; changed paths 5; areas: core, docs, feature
- Merge base: `c001a08f`
- **Disposition:** adopt (Android) — Stops encoding in-memory shared keys; fixes a shipped ANR. iOS already behaves this way.
- **iOS migration relevance:** none

### `transcript/triple-tap-paragraph` — `670abff2` — adapt (Android)

- Tip: 2026-11-16T20:35:37Z — Select a paragraph directly in a sent bubble on triple tap
- Category: divergent; ahead/behind `2/166`; unique commits 2; changed paths 7; areas: docs, feature
- Merge base: `63315581`
- **Disposition:** adapt (Android) — iOS already does triple-tap paragraph selection; useful as behaviour spec, not code.
- **iOS migration relevance:** low

### `docs-open-from-trigger` — `989664d4` — adopt (docs)

- Tip: 2026-11-19T00:58:54-05:00 — Add an open-from-the-trigger rule to the motion guidelines
- Category: divergent; ahead/behind `1/38`; unique commits 1; changed paths 1; areas: AGENTS.md
- Merge base: `d31496a3`
- **Disposition:** adopt (docs) — One motion-rule bullet.
- **iOS migration relevance:** none

### `feat/assist-default-assistant` — `4076c504` — exclude

- Tip: 2026-11-10T13:43:58Z — System: handle ASSIST so OpenCode can be the default digital assistant
- Category: divergent; ahead/behind `1/350`; unique commits 1; changed paths 2; areas: docs, feature
- Merge base: `8befa30f`
- **Disposition:** exclude — Android ASSIST intent filter; no iOS equivalent.
- **iOS migration relevance:** none

### `feat/scroll-frame-diagnostics` — `ec005c75` — defer

- Tip: 2026-11-15T19:30:37+01:00 — Export window frame timings for sidebar and transcript scrolls
- Category: divergent; ahead/behind `1/221`; unique commits 1; changed paths 10; areas: core, devtools, docs, feature
- Merge base: `10c81d8a`
- **Disposition:** defer — Window FrameMetrics per scroll surface; dev-only diagnostic, needs rework after MotionWatch removal.
- **iOS migration relevance:** none

### `fix-send-flight-landing` — `fe78fbd4` — exclude (superseded)

- Tip: 2026-11-13T03:49:02-05:00 — fix(session): land sent messages and photos cleanly in the transcript
- Category: divergent; ahead/behind `1/277`; unique commits 1; changed paths 7; areas: docs, feature
- Merge base: `5247be11`
- **Disposition:** exclude (superseded) — Fixes send-flight code deleted by #62.
- **iOS migration relevance:** none

### `pill-row-exit` — `4eabe2a6` — adopt (Android, adapt)

- Tip: 2026-11-17T02:40:04-05:00 — Keep the pill row drawn while it leaves
- Category: divergent; ahead/behind `1/149`; unique commits 1; changed paths 1; areas: feature
- Merge base: `fbeaf3bf`
- **Disposition:** adopt (Android, adapt) — Keeps a leaving composer pill drawn; matches the "animate layout something else moves" rule.
- **iOS migration relevance:** low

### `play-crashes` — `bebb140b` — adopt (Android tooling)

- Tip: 2026-11-20T23:01:13-05:00 — feat(scripts): list Google Play crashes and open issues for them
- Category: divergent; ahead/behind `1/6`; unique commits 1; changed paths 2; areas: docs, scripts
- Merge base: `c001a08f`
- **Disposition:** adopt (Android tooling) — Play Vitals crash grouping script.
- **iOS migration relevance:** none

### `session-switch-transition` — `1644438d` — exclude (policy)

- Tip: 2026-11-17T02:40:16-05:00 — Fade the transcript in when switching sessions
- Category: divergent; ahead/behind `1/149`; unique commits 1; changed paths 4; areas: docs, feature
- Merge base: `fbeaf3bf`
- **Disposition:** exclude (policy) — Crossfades session switch, contradicting the "switching views is instant" rule.
- **iOS migration relevance:** none

### `ui/settings-chevron` — `53479627` — defer (design decision)

- Tip: 2026-11-11T18:15:58-05:00 — ui(settings): show a chevron on rows that open a page
- Category: divergent; ahead/behind `1/331`; unique commits 1; changed paths 5; areas: docs, feature
- Merge base: `748ec86c`
- **Disposition:** defer (design decision) — Reverses a documented no-chevron choice; needs sign-off.
- **iOS migration relevance:** none

### `port-toolbounds` — `38498f43` — empty

- Tip: 2026-11-15T19:42:39-05:00 — Merge pull request #94 from anomalyco/port-reasoning
- Category: empty-diff; ahead/behind `1/191`; unique commits 1; changed paths 0; areas: —
- Merge base: `a11abb50`
- **Disposition:** empty — Merge commit only; zero net changes vs dev.
- **iOS migration relevance:** none

### `proto-send-native` — `efa82a22` — exclude (already integrated)

- Tip: 2026-11-14T13:08:25-05:00 — feat(transcript): bottom-anchored native list, flightless send
- Category: patch-equivalent; ahead/behind `1/244`; unique commits 1; changed paths 78; areas: AGENTS.md, core, docs, feature
- Merge base: `dafa7df8`
- **Disposition:** exclude (already integrated) — Patch-id identical to dev 809f3dd8 (#62); nothing unique.
- **iOS migration relevance:** reference

### `strings-xml-migration` — `c5dd998d` — empty

- Tip: 2026-11-14T11:12:55-05:00 — Merge pull request #66 from anomalyco/strings-outside-composables
- Category: empty-diff; ahead/behind `1/250`; unique commits 1; changed paths 0; areas: —
- Merge base: `b019bf60`
- **Disposition:** empty — Merge commit only; zero net changes.
- **iOS migration relevance:** none

## The four unrelated-history branches

These have **no merge base with dev** and were inspected as independent trees. They are the older Android port
before its history was rewritten, and they contain the only recovered iOS evidence in the repository.

| Branch | Commits | Files | `app/src` | `docs/port` | Swift | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| `glass-perf` | 163 | 526 | 401 | 101 | 4 | oldest; 78 reference images; no deviations doc |
| `glass-lens-candidate` | 325 | 633 | 436 | 166 | 4 | adds deviations/parity review; lens glass |
| `glass-look` | 329 | 636 | 436 | 169 | 4 | **newest docs for iOS `d809b1e`**; frosted glass |
| `webrtc-spike` | 353 | 662 | 454 | 167 | 4 | **newest images (iOS `16b40f7`)**; WebRTC loopback spike |

`git diff` between the three glass branches is 58 binary image files plus prose; no application code differs in a
way that changes behaviour evidence. Nothing here was merged, cherry-picked, or treated as a feature delta.

## Stale pointers worth deleting (housekeeping, not migration)

`strings-xml-migration` and `port-toolbounds` are merge commits only (`git diff dev...<branch>` empty).
`proto-send-native` is patch-identical to dev `809f3dd8`. `ios-sync-911ab132`, `android/debug-launcher-identity`,
`compose-bom-2026-11` are already in dev by different SHAs. Five branch names in this set are noise in any triage.

## What this means for the iOS rebuild

Only four branch-only items carry behaviour that the rebuilt iOS app should consider, and in every case the
behaviour already existed on iOS first — the branch is evidence, not a source:

1. **Background-run notices/replies** — notification semantics (needs-you, finished, Allow Once/Deny from the
   lock screen, inline text reply, quiet while visible, baseline captured while away). iOS reaches these through
   APNs; the *rules* are the useful part.
2. **Triple-tap paragraph selection**, **media disk-cache cap**, **raise-to-talk sensor gating** — all ports of
   iOS commits (`UserBubbleSelectableText.swift`, `#299/011ee6bd`, `#313/7393e966`); implement from the behaviour,
   not from Kotlin.
3. **`jump-previous-message`** — an Android-only affordance with no iOS counterpart in the evidence; a candidate
   for symmetric design, not a port.

Everything else is Android platform plumbing (foreground services, MMS/phone tools, ASSIST intent, Play Vitals,
R8 rules, M3 restyle) with no place in an iPhone app.
