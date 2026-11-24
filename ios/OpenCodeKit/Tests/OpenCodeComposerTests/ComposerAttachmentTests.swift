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
    var saveResult: ComposerDraftSave = .saved
    var transferResult: ComposerDraftSave = .saved
    func load(_ key: ComposerDraftKey) -> ComposerDraftLoad {
      drafts[key.storageKey].map(ComposerDraftLoad.found) ?? .missing
    }
    func save(_ draft: ComposerDraft, key: ComposerDraftKey) -> ComposerDraftSave {
      if case .saved = saveResult { drafts[key.storageKey] = draft }
      return saveResult
    }
    func setSaveResult(_ result: ComposerDraftSave) { saveResult = result }
    func setTransferResult(_ result: ComposerDraftSave) { transferResult = result }
    func remove(_ key: ComposerDraftKey) -> ComposerDraftSave {
      drafts[key.storageKey] = nil
      return .saved
    }
    func stored(_ key: ComposerDraftKey) -> ComposerDraft? { drafts[key.storageKey] }

    func referencedStoredNames(serverID: String) -> Set<String> {
      let prefix = "\(serverID)|"
      var names: Set<String> = []
      for (key, draft) in drafts where key.hasPrefix(prefix) {
        for a in draft.attachments where !a.transfer.isUploaded { names.insert(a.storedName) }
        for f in draft.failedSends {
          for a in f.attachments where !a.transfer.isUploaded { names.insert(a.storedName) }
        }
        for o in draft.outbound {
          for a in o.attachments where !a.transfer.isUploaded { names.insert(a.storedName) }
        }
      }
      return names
    }

    func applyTransfer(_ key: ComposerDraftKey, id: String, transfer: MediaTransfer) -> ComposerDraftSave {
      guard case .saved = transferResult else { return transferResult }
      guard var draft = drafts[key.storageKey],
        let index = draft.attachments.firstIndex(where: { $0.id == id })
      else { return .saved }
      draft.attachments[index].transfer = transfer
      drafts[key.storageKey] = draft
      return .saved
    }
  }

  func draftClient(_ backend: Backend) -> ComposerDraftClient {
    ComposerDraftClient(
      load: { await backend.load($0) },
      save: { await backend.save($0, key: $1) },
      remove: { await backend.remove($0) },
      applyAttachmentTransfer: { await backend.applyTransfer($0, id: $1, transfer: $2) },
      referencedStoredNames: { .success(await backend.referencedStoredNames(serverID: $0)) },
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
    client.uploadFile = { _, _, _, _, _, progress in
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
    await store.receive(.attachmentUploadFinished(key: ComposerDraftKey(serverID: server().persistenceID, scope: .session("alpha")), id: "00000000-0000-4000-8000-000000000001", attempt: 1, result: .failure(.uploadFailed))) {
      $0.attachments[0].transfer = .failed(.uploadFailed)
      $0.attachmentProblem = .uploadFailed
    }
    #expect(!store.state.canSend)
    await store.send(.attachmentRetryTapped("00000000-0000-4000-8000-000000000001")) {
      $0.attachments[0].transfer = .uploading(sent: 0)
      $0.attachmentProblem = nil
      $0.contentRevision = 3
      $0.contentUpdatedAt = Date(timeIntervalSince1970: 1_700_000_000)
    }
    await store.receive(.attachmentUploadFinished(key: ComposerDraftKey(serverID: server().persistenceID, scope: .session("alpha")), id: "00000000-0000-4000-8000-000000000001", attempt: 2, result: .success("/tmp/uploads/a/report.pdf"))) {
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
    var attempts = 0
    while FileManager.default.fileExists(atPath: url.path), attempts < 50 {
      try? await Task.sleep(for: .milliseconds(10))
      attempts += 1
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
    client.uploadFile = { _, _, _, _, uploadID, progress in
      progress(10)
      return try await gate.wait(uploadID: uploadID)
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

  @Test("upload success retains the source when the draft save fails")
  func uploadSuccessWithFailedSaveRetainsSource() async throws {
    let environment = IsolatedTestEnvironment(testName: "composer-upload-save-fail")
    defer { environment.cleanUp() }
    let files = MediaFiles(store: MediaFileStore(root: try environment.directory("stage")))
    let written = try await files.store.write(
      Data("file".utf8),
      name: "report.pdf",
      serverID: server().persistenceID,
      id: "00000000-0000-4000-8000-000000000001"
    )
    let staged = attachment(
      id: "00000000-0000-4000-8000-000000000001",
      kind: .file,
      transfer: .uploading(sent: 0),
      storedName: written.storedName
    )
    let importer = MediaImportClient(
      importImage: { _, _, _ in throw MediaAttachmentProblem.unreadable },
      importFile: { _, _, _, _ in staged },
      importPastedText: { _, _, _ in throw MediaAttachmentProblem.unreadable }
    )
    let backend = Backend()
    await backend.setSaveResult(.failure(.unavailable))
    var client = OpenCodeClient.testValue
    client.uploadFile = { _, _, _, _, _, _ in "/tmp/uploads/a/report.pdf" }
    let store = makeStore(state(), backend: backend, importer: importer, files: files, client: client)
    await store.send(.filesPicked([URL(fileURLWithPath: "/tmp/report.pdf")]))
    await store.receive(.importFinished(
      id: "00000000-0000-4000-8000-000000000001",
      target: .session(id: "alpha"),
      result: .success(staged)
    )) {
      $0.attachments = [staged]
      $0.revision = 1
      $0.contentRevision = 1
      $0.isImportingAttachments = false
      $0.importingCount = 0
    }
    await store.receive(.attachmentUploadFinished(
      key: ComposerDraftKey(serverID: self.server().persistenceID, scope: .session("alpha")),
      id: staged.id,
      attempt: 1,
      result: .success("/tmp/uploads/a/report.pdf")
    ))
    let url = await files.store.url(serverID: server().persistenceID, storedName: written.storedName)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(FileManager.default.fileExists(atPath: url.path))
    #expect(store.state.problem == .couldNotSave || store.state.problem == nil)
    let persisted = await backend.stored(ComposerDraftKey(serverID: server().persistenceID, scope: .session("alpha")))
    #expect(persisted?.attachments.first?.transfer.isUploaded != true)
  }

  @Test("a restart between upload completion and persistence restores a retryable attachment")
  func restartBeforeUploadPersistence() async throws {
    let environment = IsolatedTestEnvironment(testName: "composer-upload-restart")
    defer { environment.cleanUp() }
    let files = MediaFiles(store: MediaFileStore(root: try environment.directory("stage")))
    let written = try await files.store.write(
      Data("file".utf8),
      name: "report.pdf",
      serverID: server().persistenceID,
      id: "f1"
    )
    let staged = attachment(id: "f1", kind: .file, transfer: .uploading(sent: 20), storedName: written.storedName)
    let backend = Backend()
    let key = ComposerDraftKey(serverID: server().persistenceID, scope: .session("alpha"))
    await backend.save(ComposerDraft(text: "old", attachments: [staged], revision: 1), key: key)
    var client = OpenCodeClient.testValue
    client.uploadFile = { _, _, _, _, _, _ in "/tmp/uploads/f1/report.pdf" }
    let store = makeStore(state(), backend: backend, files: files, client: client)
    await store.send(.task)
    await store.receive(.draftLoaded(token: 1, key: key, outcome: .found(
      ComposerDraft(text: "old", attachments: [staged], revision: 1)
    ))) {
      $0.draft = "old"
      $0.attachments = [self.attachment(id: "f1", kind: .file, transfer: .failed(.uploadInterrupted), storedName: written.storedName)]
      $0.contentRevision = 1
    }
    let url = await files.store.url(serverID: server().persistenceID, storedName: written.storedName)
    #expect(FileManager.default.fileExists(atPath: url.path))
    #expect(store.state.attachments.first?.isReady == false)
    await store.send(.attachmentRetryTapped("f1"))
    var attempts = 0
    while FileManager.default.fileExists(atPath: url.path), attempts < 50 {
      try? await Task.sleep(for: .milliseconds(10))
      attempts += 1
    }
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }

  @Test("a failed removal save leaves the staged file for restore")
  func removalSaveFailureKeepsFile() async throws {
    let environment = IsolatedTestEnvironment(testName: "composer-remove-save-fail")
    defer { environment.cleanUp() }
    let files = MediaFiles(store: MediaFileStore(root: try environment.directory("stage")))
    let written = try await files.store.write(
      Data("file".utf8),
      name: "report.tmp",
      serverID: server().persistenceID,
      id: "f1"
    )
    var initial = state()
    initial.attachments = [attachment(id: "f1", kind: .file, transfer: .uploaded(path: "/tmp/f1"), storedName: written.storedName)]
    let backend = Backend()
    await backend.setSaveResult(.failure(.unavailable))
    let store = makeStore(initial, backend: backend, files: files)
    await store.send(.attachmentRemoveTapped("f1"))
    try? await Task.sleep(for: .milliseconds(50))
    let url = await files.store.url(serverID: server().persistenceID, storedName: written.storedName)
    #expect(FileManager.default.fileExists(atPath: url.path))
  }

  @Test("an unresolved outbound record keeps the staged source")
  func unresolvedOutboundKeepsSource() async throws {
    let environment = IsolatedTestEnvironment(testName: "composer-outbound-source")
    defer { environment.cleanUp() }
    let files = MediaFiles(store: MediaFileStore(root: try environment.directory("stage")))
    let written = try await files.store.write(
      Data("file".utf8),
      name: "report.tmp",
      serverID: server().persistenceID,
      id: "f1"
    )
    let staged = attachment(id: "f1", kind: .file, transfer: .failed(.uploadFailed), storedName: written.storedName)
    var initial = state()
    initial.attachments = [staged]
    initial.outbound = [
      ComposerOutbound(
        target: .session(id: "alpha"),
        messageID: "m1",
        text: "old",
        quotes: [],
        attachments: [staged],
        delivery: .steer,
        revision: 1
      )
    ]
    let store = makeStore(initial, backend: Backend(), files: files)
    await store.send(.attachmentRemoveTapped("f1"))
    try? await Task.sleep(for: .milliseconds(50))
    let url = await files.store.url(serverID: server().persistenceID, storedName: written.storedName)
    #expect(FileManager.default.fileExists(atPath: url.path))
  }

  @Test("a viewer lease keeps the source until cleanup can run again")
  func viewerLeaseKeepsSource() async throws {
    let environment = IsolatedTestEnvironment(testName: "composer-viewer-lease")
    defer { environment.cleanUp() }
    let files = MediaFiles(store: MediaFileStore(root: try environment.directory("stage")))
    let written = try await files.store.write(
      Data("file".utf8),
      name: "capture.partial",
      serverID: server().persistenceID,
      id: "f1"
    )
    let token = await files.store.lease(serverID: server().persistenceID, storedName: written.storedName)
    var initial = state()
    initial.attachments = [attachment(id: "f1", kind: .file, transfer: .uploaded(path: "/tmp/f1"), storedName: written.storedName)]
    let store = makeStore(initial, backend: Backend(), files: files)
    await store.send(.attachmentRemoveTapped("f1"))
    try? await Task.sleep(for: .milliseconds(50))
    let url = await files.store.url(serverID: server().persistenceID, storedName: written.storedName)
    #expect(FileManager.default.fileExists(atPath: url.path))
    await files.store.release(token)
    await store.send(.flush)
    var attempts = 0
    while FileManager.default.fileExists(atPath: url.path), attempts < 50 {
      try? await Task.sleep(for: .milliseconds(10))
      attempts += 1
    }
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }

  @Test("an upload started on A completes while B is visible and A restores it")
  func uploadCompletesWhileAnotherDraftIsVisible() async throws {
    let environment = IsolatedTestEnvironment(testName: "composer-upload-navigation")
    defer { environment.cleanUp() }
    let files = MediaFiles(store: MediaFileStore(root: try environment.directory("stage")))
    let written = try await files.store.write(
      Data("file".utf8),
      name: "report.pdf",
      serverID: server().persistenceID,
      id: "f1"
    )
    let staged = attachment(id: "f1", kind: .file, transfer: .uploading(sent: 0), storedName: written.storedName)
    let importer = MediaImportClient(
      importImage: { _, _, _ in throw MediaAttachmentProblem.unreadable },
      importFile: { _, _, _, _ in staged },
      importPastedText: { _, _, _ in throw MediaAttachmentProblem.unreadable }
    )
    let backend = Backend()
    let beta = ComposerDraftKey(serverID: server().persistenceID, scope: .session("beta"))
    await backend.save(ComposerDraft(text: "B draft", revision: 3), key: beta)
    let gate = UploadGate()
    var client = OpenCodeClient.testValue
    client.uploadFile = { _, _, _, _, uploadID, progress in
      progress(1)
      return try await gate.wait(uploadID: uploadID)
    }
    let store = makeStore(state(), backend: backend, importer: importer, files: files, client: client)
    await store.send(.filesPicked([URL(fileURLWithPath: "/tmp/report.pdf")]))
    await store.receive(.importFinished(
      id: "00000000-0000-4000-8000-000000000001",
      target: .session(id: "alpha"),
      result: .success(staged)
    ))
    await store.send(.switchTarget(.session(id: "beta")))
    await store.receive(.draftLoaded(
      token: 1,
      key: beta,
      outcome: .found(ComposerDraft(text: "B draft", revision: 3))
    ))
    #expect(store.state.target == .session(id: "beta"))
    await gate.finish("/tmp/uploads/f1/report.pdf")
    await store.receive(.attachmentUploadFinished(
      key: ComposerDraftKey(serverID: self.server().persistenceID, scope: .session("alpha")),
      id: "f1",
      attempt: 1,
      result: .success("/tmp/uploads/f1/report.pdf")
    ))
    try? await Task.sleep(for: .milliseconds(80))
    let alpha = ComposerDraftKey(serverID: server().persistenceID, scope: .session("alpha"))
    let persistedA = await backend.stored(alpha)
    #expect(persistedA?.attachments.first?.fileReference?.path == "/tmp/uploads/f1/report.pdf")
    let persistedB = await backend.stored(beta)
    #expect(persistedB?.text == "B draft")
    await store.send(.switchTarget(.session(id: "alpha")))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(store.state.attachments.first?.transfer == .uploaded(path: "/tmp/uploads/f1/report.pdf"))
  }

  @Test("an older upload completion cannot overwrite a newer retry")
  func oldCompletionAfterRetryIsIgnored() async throws {
    let environment = IsolatedTestEnvironment(testName: "composer-upload-attempt")
    defer { environment.cleanUp() }
    let files = MediaFiles(store: MediaFileStore(root: try environment.directory("stage")))
    let written = try await files.store.write(
      Data("file".utf8),
      name: "report.pdf",
      serverID: server().persistenceID,
      id: "f1"
    )
    let staged = attachment(id: "f1", kind: .file, transfer: .uploading(sent: 0), storedName: written.storedName)
    let importer = MediaImportClient(
      importImage: { _, _, _ in throw MediaAttachmentProblem.unreadable },
      importFile: { _, _, _, _ in staged },
      importPastedText: { _, _, _ in throw MediaAttachmentProblem.unreadable }
    )
    let backend = Backend()
    let alpha = ComposerDraftKey(serverID: server().persistenceID, scope: .session("alpha"))
    let gate = UploadGate()
    var client = OpenCodeClient.testValue
    client.uploadFile = { _, _, _, _, uploadID, _ in
      return try await gate.wait(uploadID: uploadID)
    }
    let store = makeStore(state(), backend: backend, importer: importer, files: files, client: client)
    await store.send(.filesPicked([URL(fileURLWithPath: "/tmp/report.pdf")]))
    await store.receive(.importFinished(
      id: "00000000-0000-4000-8000-000000000001",
      target: .session(id: "alpha"),
      result: .success(staged)
    ))
    await store.send(.switchTarget(.session(id: "beta")))
    await store.send(.switchTarget(.session(id: "alpha")))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(store.state.attachments.first?.transfer == .failed(.uploadInterrupted))
    await store.send(.attachmentRetryTapped("f1"))
    // A dependency may complete after cancellation. The older attempt must not win.
    await store.send(.attachmentUploadFinished(
      key: alpha,
      id: "f1",
      attempt: 1,
      result: .success("/tmp/uploads/old/report.pdf")
    ))
    #expect(store.state.attachments.first?.transfer != .uploaded(path: "/tmp/uploads/old/report.pdf"))
    await gate.finish(index: 1, "/tmp/uploads/new/report.pdf")
    await store.receive(.attachmentUploadFinished(
      key: alpha,
      id: "f1",
      attempt: 2,
      result: .success("/tmp/uploads/new/report.pdf")
    ))
    #expect(store.state.attachments.first?.transfer == .uploaded(path: "/tmp/uploads/new/report.pdf"))
    let persisted = await backend.stored(alpha)
    #expect(persisted?.attachments.first?.fileReference?.path == "/tmp/uploads/new/report.pdf")
  }

  @Test("a hidden upload persistence failure keeps the source and retries on return")
  func hiddenUploadPersistenceFailureRetries() async throws {
    let environment = IsolatedTestEnvironment(testName: "composer-hidden-upload-failure")
    defer { environment.cleanUp() }
    let files = MediaFiles(store: MediaFileStore(root: try environment.directory("stage")))
    let written = try await files.store.write(
      Data("file".utf8),
      name: "report.pdf",
      serverID: server().persistenceID,
      id: "f1"
    )
    let staged = attachment(id: "f1", kind: .file, transfer: .uploading(sent: 0), storedName: written.storedName)
    let importer = MediaImportClient(
      importImage: { _, _, _ in throw MediaAttachmentProblem.unreadable },
      importFile: { _, _, _, _ in staged },
      importPastedText: { _, _, _ in throw MediaAttachmentProblem.unreadable }
    )
    let backend = Backend()
    let gate = UploadGate()
    var client = OpenCodeClient.testValue
    client.uploadFile = { _, _, _, _, uploadID, _ in
      try await gate.wait(uploadID: uploadID)
    }
    let store = makeStore(state(), backend: backend, importer: importer, files: files, client: client)
    let alpha = ComposerDraftKey(serverID: server().persistenceID, scope: .session("alpha"))
    await store.send(.filesPicked([URL(fileURLWithPath: "/tmp/report.pdf")]))
    await store.receive(.importFinished(
      id: "00000000-0000-4000-8000-000000000001",
      target: .session(id: "alpha"),
      result: .success(staged)
    ))
    await store.send(.switchTarget(.session(id: "beta")))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    await backend.setTransferResult(.failure(.unavailable))
    await gate.finish("/tmp/uploads/f1/report.pdf")
    await store.receive(.attachmentDeferred(
      ComposerFeature.State.AttachmentUploadID(key: alpha, attachmentID: "f1"),
      .uploaded(path: "/tmp/uploads/f1/report.pdf")
    ))
    #expect(store.state.problem == .couldNotSave)
    let url = await files.store.url(serverID: server().persistenceID, storedName: written.storedName)
    #expect(FileManager.default.fileExists(atPath: url.path))
    #expect(await backend.stored(alpha)?.attachments.first?.transfer.isUploaded == false)
    await backend.setTransferResult(.saved)
    await store.send(.switchTarget(.session(id: "alpha")))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(store.state.attachments.first?.transfer == .uploaded(path: "/tmp/uploads/f1/report.pdf"))
    var attempts = 0
    while FileManager.default.fileExists(atPath: url.path), attempts < 50 {
      try? await Task.sleep(for: .milliseconds(10))
      attempts += 1
    }
    #expect(!FileManager.default.fileExists(atPath: url.path))
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
  private var pending: [CheckedContinuation<String, any Error>] = []
  private(set) var uploadIDs: [String] = []

  func wait(uploadID: String) async throws -> String {
    uploadIDs.append(uploadID)
    return try await withCheckedThrowingContinuation { continuation in
      pending.append(continuation)
    }
  }

  func finish(_ path: String) {
    guard !pending.isEmpty else { return }
    pending.removeFirst().resume(returning: path)
  }

  func finish(index: Int, _ path: String) {
    guard pending.indices.contains(index) else { return }
    pending.remove(at: index).resume(returning: path)
  }

  func count() -> Int { pending.count }
}
