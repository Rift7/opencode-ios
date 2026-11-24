import ComposableArchitecture
import Foundation
import OpenCodeComposer
import OpenCodeCore
import OpenCodeMedia
import OpenCodeServer
import OpenCodeTestSupport
import Testing

@MainActor
@Suite("Composer attachments", .serialized)
struct ComposerAttachmentTests {
  actor Backend {
    var drafts: [String: ComposerDraft] = [:]
    func load(_ key: ComposerDraftKey) -> ComposerDraftLoad {
      drafts[key.storageKey].map(ComposerDraftLoad.found) ?? .missing
    }
    func save(_ draft: ComposerDraft, key: ComposerDraftKey) -> ComposerDraftSave {
      drafts[key.storageKey] = draft
      return .saved
    }
    func remove(_ key: ComposerDraftKey) -> ComposerDraftSave {
      drafts[key.storageKey] = nil
      return .saved
    }
    func stored(_ key: ComposerDraftKey) -> ComposerDraft? { drafts[key.storageKey] }
  }

  func draftClient(_ backend: Backend) -> ComposerDraftClient {
    ComposerDraftClient(
      load: { await backend.load($0) },
      save: { await backend.save($0, key: $1) },
      remove: { await backend.remove($0) },
      flush: {}
    )
  }

  nonisolated func server() -> OpenCodeServer {
    OpenCodeServer(url: "https://wire-00000000-0000-4000-8000-000000000000.invalid", password: "test")
  }

  func state(scope: ComposerScope = .session("alpha")) -> ComposerFeature.State {
    var state = ComposerFeature.State(
      serverID: server().persistenceID,
      target: .session(id: "alpha")
    )
    state.server = server()
    state.uploadDirectory = "/work/app"
    return state
  }

  nonisolated func attachment(
    id: String = "a1",
    kind: MediaAttachmentKind = .image,
    transfer: MediaTransfer = .inline,
    storedName: String = "a1/image.jpg"
  ) -> MediaAttachment {
    MediaAttachment(
      id: id,
      kind: kind,
      name: kind == .image ? "Image.jpg" : "report.pdf",
      mime: kind == .image ? "image/jpeg" : "application/pdf",
      byteCount: 100,
      storedName: storedName,
      transfer: transfer,
      pixelWidth: 640,
      pixelHeight: 480
    )
  }

  func makeStore(
    _ initial: ComposerFeature.State,
    backend: Backend,
    importer: MediaImportClient? = nil,
    files: MediaFiles? = nil,
    client: OpenCodeClient = .testValue
  ) -> TestStoreOf<ComposerFeature> {
    let store = TestStore(initialState: initial) {
      ComposerFeature()
    } withDependencies: {
      $0.composerDrafts = draftClient(backend)
      $0.clock = .testValue
      $0.uuidClient = .incrementing()
      $0.dateClient = DateClient { Date(timeIntervalSince1970: 1_700_000_000) }
      $0.haptics = .testValue
      $0.openCodeClient = client
      if let importer { $0.mediaImporter = importer }
      if let files { $0.mediaFiles = files }
    }
    store.exhaustivity = .off
    return store
  }

  @Test("a draft saved before attachments decodes them as empty")
  func legacyDraftDecodesWithoutAttachments() throws {
    let data = Data(
      #"{"text":"hello","quotes":[],"failedSends":[],"outbound":[],"revision":1,"updatedAt":0}"#.utf8
    )
    let draft = try JSONDecoder().decode(ComposerDraft.self, from: data)
    #expect(draft.attachments.isEmpty)
    #expect(draft.text == "hello")
  }

  @Test("an attachment survives the draft's JSON round trip")
  func attachmentDraftRoundTrip() throws {
    let draft = ComposerDraft(text: "hello", attachments: [attachment()], revision: 2)
    let data = try JSONEncoder().encode(draft)
    let decoded = try JSONDecoder().decode(ComposerDraft.self, from: data)
    #expect(decoded == draft)
    #expect(decoded.boundedProblem() == nil)
  }

  @Test("an imported photo is staged as a ready attachment and can be sent")
  func importImageAndSend() async throws {
    let backend = Backend()
    let importer = MediaImportClient(
      importImage: { _, _, id in attachment(id: id) },
      importFile: { _, _, _, _ in throw MediaAttachmentProblem.unreadable },
      importPastedText: { _, _, _ in throw MediaAttachmentProblem.unreadable }
    )
    let store = makeStore(state(), backend: backend, importer: importer)
    await store.send(.photosPicked([Data("jpeg".utf8)]))
    await store.receive(.importFinished(id: "00000000-0000-4000-8000-000000000001", target: .session(id: "alpha"), result: .success(attachment(id: "00000000-0000-4000-8000-000000000001")))) {
      $0.attachments = [self.attachment(id: "00000000-0000-4000-8000-000000000001")]
      $0.revision = 1
      $0.contentRevision = 1
      $0.contentUpdatedAt = Date(timeIntervalSince1970: 1_700_000_000)
      $0.isImportingAttachments = false
      $0.importingCount = 0
    }
    #expect(store.state.canSend)
    await store.send(.sendTapped)
    #expect(store.state.outbound.first?.attachments.count == 1)
    #expect(store.state.outbound.first?.attachments.first?.id == "00000000-0000-4000-8000-000000000001")
  }

  @Test("a failed upload keeps its source, and Retry uploads it")
  func uploadFailureAndRetry() async throws {
    let backend = Backend()
    let attempts = Counter()
    let importer = MediaImportClient(
      importImage: { _, _, _ in throw MediaAttachmentProblem.unreadable },
      importFile: { _, _, _, id in
        attachment(
          id: id,
          kind: .file,
          transfer: .uploading(sent: 0),
          storedName: "\(id)/report.pdf"
        )
      },
      importPastedText: { _, _, _ in throw MediaAttachmentProblem.unreadable }
    )
    var client = OpenCodeClient.testValue
    client.uploadFile = { _, _, _, _, progress in
      let attempt = await attempts.next()
      progress(50)
      if attempt == 1 { throw OpenCodeClientError(.status(500)) }
      return "/tmp/uploads/a/report.pdf"
    }
    let store = makeStore(state(), backend: backend, importer: importer, client: client)
    await store.send(.filesPicked([URL(fileURLWithPath: "/tmp/report.pdf")]))
    await store.receive(.importFinished(id: "00000000-0000-4000-8000-000000000001", target: .session(id: "alpha"), result: .success(
      attachment(id: "00000000-0000-4000-8000-000000000001", kind: .file, transfer: .uploading(sent: 0), storedName: "00000000-0000-4000-8000-000000000001/report.pdf")
    ))) {
      $0.attachments = [self.attachment(id: "00000000-0000-4000-8000-000000000001", kind: .file, transfer: .uploading(sent: 0), storedName: "00000000-0000-4000-8000-000000000001/report.pdf")]
      $0.revision = 1
      $0.contentRevision = 1
      $0.isImportingAttachments = false
      $0.importingCount = 0
    }
    await store.receive(.attachmentUploadFinished(id: "00000000-0000-4000-8000-000000000001", result: .failure(.uploadFailed))) {
      $0.attachments[0].transfer = .failed(.uploadFailed)
      $0.attachmentProblem = .uploadFailed
    }
    #expect(!store.state.canSend)
    await store.send(.attachmentRetryTapped("00000000-0000-4000-8000-000000000001")) {
      $0.attachments[0].transfer = .uploading(sent: 0)
      $0.attachmentProblem = nil
      $0.contentRevision = 2
      $0.contentUpdatedAt = Date(timeIntervalSince1970: 1_700_000_000)
    }
    await store.receive(.attachmentUploadFinished(id: "00000000-0000-4000-8000-000000000001", result: .success("/tmp/uploads/a/report.pdf"))) {
      $0.attachments[0].transfer = .uploaded(path: "/tmp/uploads/a/report.pdf")
      $0.attachmentProblem = nil
    }
    #expect(store.state.canSend)
    #expect(store.state.attachments.first?.fileReference?.path == "/tmp/uploads/a/report.pdf")
  }

  @Test("an inline image and an uploaded path both reach the prompt")
  func promptEncoding() throws {
    let image = attachment()
    let file = attachment(
      id: "f1",
      kind: .file,
      transfer: .uploaded(path: "/tmp/uploads/f1/report.pdf"),
      storedName: "f1/report.pdf"
    )
    let send = ComposerSend(
      target: .session(id: "alpha"),
      messageID: "m1",
      text: "Look",
      quotes: [ComposerQuote(text: "quoted")],
      attachments: [image, file],
      delivery: .steer,
      revision: 1
    )
    let prompt = send.prompt(inlineData: ["a1": Data("image-bytes".utf8)])
    #expect(prompt.id == "m1")
    #expect(prompt.files?.count == 1)
    #expect(prompt.files?.first?.uri.hasPrefix("data:image/jpeg;base64,") == true)
    #expect(prompt.metadata?.attachments?.first?.path == "/tmp/uploads/f1/report.pdf")
    #expect(prompt.text.contains("Attached file: `/tmp/uploads/f1/report.pdf`"))
    #expect(prompt.metadata?.comments?.first?.type == "quote")
  }

  @Test("removing an attachment does not delete a file a failed send still owns")
  func removalRespectsFailedOwnership() async throws {
    let environment = IsolatedTestEnvironment(testName: "composer-attachment-ownership")
    defer { environment.cleanUp() }
    let storeURL = try environment.directory("stage")
    let files = MediaFiles(store: MediaFileStore(root: storeURL))
    let written = try await files.store.write(
      Data("image".utf8),
      name: "image.jpg",
      serverID: server().persistenceID,
      id: "a1"
    )
    let owned = self.attachment(storedName: written.storedName)
    var initial = state()
    initial.attachments = [owned]
    initial.failedSends = [
      FailedComposerSend(
        messageID: "failed",
        text: "old",
        quotes: [],
        attachments: [owned],
        delivery: .steer,
        target: .session(id: "alpha"),
        reason: .couldNotSend,
        failure: .definite
      )
    ]
    let store = makeStore(initial, backend: Backend(), files: files)
    await store.send(.attachmentRemoveTapped("a1")) {
      $0.attachments = []
      $0.revision = 1
      $0.contentRevision = 1
      $0.contentUpdatedAt = Date(timeIntervalSince1970: 1_700_000_000)
    }
    let url = await files.store.url(serverID: server().persistenceID, storedName: written.storedName)
    #expect(FileManager.default.fileExists(atPath: url.path))

    var standalone = state()
    standalone.attachments = [owned]
    let second = makeStore(standalone, backend: Backend(), files: files)
    await second.send(.attachmentRemoveTapped("a1")) {
      $0.attachments = []
      $0.revision = 1
      $0.contentRevision = 1
      $0.contentUpdatedAt = Date(timeIntervalSince1970: 1_700_000_000)
    }
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }

  @Test("restoring an interrupted upload exposes a safe retry")
  func interruptedUploadRestoresAsFailure() async throws {
    let backend = Backend()
    let key = ComposerDraftKey(serverID: server().persistenceID, scope: .session("alpha"))
    await backend.save(
      ComposerDraft(
        text: "hello",
        attachments: [
          attachment(id: "f1", kind: .file, transfer: .uploading(sent: 50), storedName: "f1/report.pdf")
        ],
        revision: 1,
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
      ),
      key: key
    )
    let store = makeStore(state(), backend: backend)
    await store.send(.task)
    await store.receive(.draftLoaded(token: 1, key: key, outcome: .found(
      ComposerDraft(
        text: "hello",
        attachments: [
          attachment(id: "f1", kind: .file, transfer: .uploading(sent: 50), storedName: "f1/report.pdf")
        ],
        revision: 1,
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
      )
    ))) {
      $0.draft = "hello"
      $0.attachments = [
        self.attachment(id: "f1", kind: .file, transfer: .failed(.uploadInterrupted), storedName: "f1/report.pdf")
      ]
      $0.contentRevision = 1
      $0.contentUpdatedAt = Date(timeIntervalSince1970: 1_700_000_000)
    }
    #expect(store.state.attachments.first?.isReady == false)
  }

  @Test("a late import for the previous target cannot land in a new draft")
  func lateImportIsFenced() async {
    let store = makeStore(state(), backend: Backend())
    await store.send(.switchTarget(.session(id: "beta")))
    #expect(store.state.target == .session(id: "beta"))
    await store.send(
      .importFinished(
        id: "late",
        target: .session(id: "alpha"),
        result: .success(attachment(id: "late"))
      )
    )
    #expect(store.state.attachments.isEmpty)
  }

  @Test("removing an attachment during upload cancels it and a late result changes nothing")
  func removeDuringUpload() async throws {
    let gate = UploadGate()
    var client = OpenCodeClient.testValue
    client.uploadFile = { _, _, _, _, progress in
      progress(10)
      return try await gate.wait()
    }
    let importer = MediaImportClient(
      importImage: { _, _, _ in throw MediaAttachmentProblem.unreadable },
      importFile: { _, _, _, id in
        attachment(id: id, kind: .file, transfer: .uploading(sent: 0), storedName: "\(id)/report.pdf")
      },
      importPastedText: { _, _, _ in throw MediaAttachmentProblem.unreadable }
    )
    let store = makeStore(state(), backend: Backend(), importer: importer, client: client)
    await store.send(.filesPicked([URL(fileURLWithPath: "/tmp/report.pdf")]))
    await store.receive(.importFinished(
      id: "00000000-0000-4000-8000-000000000001",
      target: .session(id: "alpha"),
      result: .success(
        attachment(
          id: "00000000-0000-4000-8000-000000000001",
          kind: .file,
          transfer: .uploading(sent: 0),
          storedName: "00000000-0000-4000-8000-000000000001/report.pdf"
        )
      )
    )) {
      $0.attachments = [
        self.attachment(
          id: "00000000-0000-4000-8000-000000000001",
          kind: .file,
          transfer: .uploading(sent: 0),
          storedName: "00000000-0000-4000-8000-000000000001/report.pdf"
        )
      ]
      $0.revision = 1
      $0.contentRevision = 1
      $0.isImportingAttachments = false
      $0.importingCount = 0
    }
    await store.send(.attachmentRemoveTapped("00000000-0000-4000-8000-000000000001")) {
      $0.attachments = []
      $0.revision = 2
      $0.contentRevision = 2
      $0.contentUpdatedAt = Date(timeIntervalSince1970: 1_700_000_000)
    }
    await gate.finish("/tmp/uploads/a/report.pdf")
    await Task.yield()
    #expect(store.state.attachments.isEmpty)
    #expect(store.state.outbound.isEmpty)
  }

  @Test("the attachment limit refuses extras without dropping what is already staged")
  func attachmentLimit() async throws {
    let backend = Backend()
    let importer = MediaImportClient(
      importImage: { _, _, id in attachment(id: id) },
      importFile: { _, _, _, _ in throw MediaAttachmentProblem.unreadable },
      importPastedText: { _, _, _ in throw MediaAttachmentProblem.unreadable }
    )
    var initial = state()
    initial.attachments = (0..<MediaLimits.maximumAttachments).map { attachment(id: "a\($0)") }
    initial.importingCount = 0
    let store = makeStore(initial, backend: backend, importer: importer)
    await store.send(.photosPicked([Data("x".utf8)])) {
      $0.attachmentProblem = .tooLarge
    }
    #expect(store.state.attachments.count == MediaLimits.maximumAttachments)
  }
}

private actor Counter {
  private var value = 0
  func next() -> Int {
    value += 1
    return value
  }
}

private actor UploadGate {
  private var continuation: CheckedContinuation<String, any Error>?

  func wait() async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
    }
  }

  func finish(_ path: String) {
    continuation?.resume(returning: path)
    continuation = nil
  }
}
