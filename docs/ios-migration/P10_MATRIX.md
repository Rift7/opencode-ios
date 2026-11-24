# P10 acceptance matrix — media, files, browser and rendering

Phase 10 of the iOS migration, against the behaviour baseline `7358160e` and the P10 base
`origin/ios = e42cb455` (PR #8 merged; corrected P9 tree `1fd90423` equals merged tree `62d44987`).
Every "done" row has a test in this repository. "Unverified" rows run only on hardware or a live V2 server.

## Imports and staging

| Contract | Evidence | Status / limit |
| --- | --- | --- |
| Photo import through `PhotosPicker` | `ios/OpenCode/Composer/ComposerViews.swift`; `MediaUITests.testComposerPastePreviewAndRemove` covers the picker-adjacent chip path | done for images; picker videos not requested |
| Camera import, permission on invocation, denied/unavailable | `CameraCaptureSheet.swift`; `NSCameraUsageDescription` | done through the system capture UI; physical camera unverified |
| Document import with security-scoped copy and cleanup | `ComposerViews.swift` `.fileImporter`; `MediaFileStore.copyFile` opens and always closes the scope | done; provider latency/eviction unverified |
| Paste images/files/long text; ordinary typing untouched | `ComposerTextInput.paste`, `ComposerFeature.pasteTapped`, `MediaLimits.isLongPaste` | done — only an explicit paste or a >1,000-character / >12-line paste becomes an attachment |
| Staged copy before a picker grant expires | `MediaImportClient`, `MediaFileStore`; no picker URL is persisted | done |
| Type and size from actual bytes | `MediaFileType.mime` (4 KiB head), image decode and 20 MB source cap, 100 MB file cap | done |
| Image re-encode: 1,568 px long edge, JPEG 0.8, EXIF dropped, never upscale | `MediaImageEncoding`, `MediaImportTests` | done |
| Corrupt/unsupported/oversized/cancelled imports | `MediaImportTests`; reducer `.importFinished(.failure)` | done for malformed images, oversize, write failures; cancellation is a typed path but has no UI-injected cancellation test |
| Attachment chips: name/type/size, progress, retry, removal, accessibility | `ComposerAttachmentChip`; `MediaUITests` paste/preview/remove | done |

## Durable ownership and upload

| Contract | Evidence | Status / limit |
| --- | --- | --- |
| Stable references in the P9 draft, failed-send and outbound records | `ComposerDraft.attachments`, `FailedComposerSend.attachments`, `ComposerOutbound.attachments`; `ComposerAttachmentTests` | done; legacy records decode with no attachments |
| Caption, quotes and selections preserved while importing | attachments are additive; `ComposerDraft.sameContent` includes them | done |
| Restart during import/upload/send | `.uploading` restores as `.failed(.uploadInterrupted)` with the local source; outbound restores as unverified per P9 | done in reducer tests; no kill-in-the-middle device run |
| Removal/navigation/server switch during upload | cancel id per attachment; `importFinished` carries the target and is ignored after a switch; `removeDuringUpload` and `lateImportIsFenced` | done |
| No duplicate upload or prompt on retry | one upload path per attachment reused across retries; prompt remains one admission per message ID (P9) | done for route/retry shape; live idempotency unverified |
| Cancel before dispatch | upload effect checks cancellation before emitting; send path checks before the prompt mutation (P9) | done |
| Actual prompt encoding | inline JPEG/paste `data:` parts; uploaded path reference lines; `metadata.attachments`; quotes as `metadata.comments` | `ComposerAttachmentTests.promptEncoding`; live server unverified |
| File release only after confirmed ownership ends | `releaseIfUnreferenced` against draft, failed and outbound records; test removes a draft attachment while a failed send owns it | done |
| Upload capability discovery | `/api/info` `paths.tmp`; otherwise `.unsupported`; `MediaClientTests.uploadUnsupported` | done; real V2 server unavailable |

## Transcript and viewers

| Contract | Evidence | Status / limit |
| --- | --- | --- |
| Inline/media-hash image tiles with reserved aspect | `UserImagesRow`, `MediaThumbnail` | done |
| Tool image mosaic | `ToolRow`; `MediaUITests.testTranscriptImageGalleryAndToolMosaic` | done |
| Gallery navigation, stable page identity | `MediaViewerFeature.pages/index`; swipe + dots | done |
| Zoom/pan and double-tap reset | `ZoomScrollView` (UIScrollView) | done |
| Drag-to-dismiss and close | `MediaViewerView` drag threshold + close; Reduce Motion fade on the spring-back only | done; no custom open/close flight |
| Loading/retry/unavailable per page | `MediaPageLoad`, `retryTapped`, `imageUnavailable` | done |
| Video/audio playback | authenticated download to a Caches scratch file, then AVPlayer | done; interruptions unverified |
| PDF | authenticated download, `PDFView` | done |
| Transcript position and composer content survive a viewer | viewer is a `@Presents` child; no transcript mutation | done; no explicit position test |
| Authenticated media stays separate from external URLs | blobs only through `OpenCodeClient.mediaBlob`; Markdown images remain cards; external links confirm | done; redirect policy reuses the transport rule |
| Gallery from composer pending images | preview sheet + annotation | done |

## Server files and annotation

| Contract | Evidence | Status / limit |
| --- | --- | --- |
| `fs/list` and bounded `fs/read` | `Operations.listDirectory/readFile`, `MediaClientTests.fileReadAndListing` | done; folder-browser UI not surfaced |
| Server paths are remote identifiers, never local reads | `AgentFilePath`, `FileViewerFeature`; test uses `/work/app` and `/tmp`, no local open | done |
| Code preview with line numbers and bounded highlighting | `CodePreview` (64 KiB/1,500 lines/4 KiB line), `CodeHighlighter` | done; fallback to plain lines for long content |
| Binary/unsupported fallback | `FileViewerFeature` kind and `.unsupported` | done |
| Annotation: original immutable, atomic staged result, return to originating composer | `AnnotationRenderer` builds a new JPEG; `drawingAdded` imports it into the same composer; cancel only dismisses | done; UI Add journey |
| Copy/export/share | transcript copy, file ShareLink for text, shell Copy/Share | done; share extension is P12 |
| Background subagent stop | `SessionFeature.backgroundSubagentStopTapped` interrupts an active child and cancels jobs owned by it or its subtree; `SessionMediaTests.subagentStop` | done |

## Browser

| Contract | Evidence | Status / limit |
| --- | --- | --- |
| Experimental, off by default | `MediaExperiments` reads `in-app-browser` (default false); DEBUG UI-test argument only | done; Settings switch is P11 |
| Public `http(s)` pages only | `BrowserLinkPolicy`, tests for loopback/private/IP/credentials/signed query | done |
| Navigation hands private/other schemes to the system; pairing links never load | `BrowserNavigationPolicy`, tests | done |
| Downloads and unshowable responses go to the system | `decidePolicyFor navigationResponse`, `handsToSystem` | done |
| Non-persistent storage, no script bridge, no file access | `WKWebsiteDataStore.nonPersistent()`, no `WKScriptMessageHandler`, default file access off | done |
| Server credentials never injected | the browser has no server object and no auth headers | done |
| Fallback when content cannot load | `didFail` overlay with Try Again; policy test | done |
| Ask / page context prompt | — | deferred to P14 |

## Rendering and selection

| Contract | Evidence | Status / limit |
| --- | --- | --- |
| Math | P8 Markdown keeps the source in a code band | explicit final source fallback; no renderer dependency |
| Mermaid | P8 renders an ordinary fenced code block | explicit final source fallback; no bundled JS/WebView renderer |
| Offline, licensing, untrusted content | evaluation recorded in D-87; falling back avoids executable page content | accepted by the phase instructions |
| Cross-block selection | per-block `.textSelection` and reply Copy remain | deferred to P14 with a concrete check |

## Cache and cleanup

| Contract | Evidence | Status / limit |
| --- | --- | --- |
| Bounded media blob disk cache | 256 MiB, oldest finished `.blob` first, never a `.partial`; `MediaReferenceCacheTests.diskTrim` | done |
| Bounded memory and decoded image caches | 48 MiB/64 entries and 64 MiB/96 entries; memory warning clears/trims | done in tests; device warning unverified |
| Draft/staged files are not cache entries | Application Support `ComposerAttachments`; cache trim never touches it | done |
| Partition authenticated content | blob identity is content hash; 404s are per server persistence ID; server file reads are scoped to their location | done |
| Failed/partial writes | atomic image/attachment writes; staging folder removed on failure; launch removes `.partial`/`.tmp` and scratch | done |
| Orphan sweep | — | deferred to P14 (recipe and acceptance in STATUS) |

## Test inventory

- Package: 532 tests — 198 server, 67 core, 75 app, 38 drawer, 70 session, 36 composer, 26 transcript,
  22 media.
- UI: 70 tests, including 8 `MediaUITests`, 1 `MediaScreenshotUITests`, 3 `MediaPerformanceUITests`.
- Screenshots: 16 P10 light/dark captures under `docs/ios-migration/screens/`.
