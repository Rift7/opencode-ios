import ComposableArchitecture
import Foundation
import OpenCodeComposer
import OpenCodeCore
import OpenCodeServer
import OpenCodeSession
import OpenCodeTestSupport
import Synchronization
import Testing

@MainActor
@Suite("Folder browser", .serialized)
struct FolderBrowserTests {
  private let server = OpenCodeServer(url: "http://127.0.0.1:4110", password: "token")

  private final class Paths: Sendable {
    private let values = Mutex<[String?]>([])
    func append(_ path: String?) { values.withLock { $0.append(path) } }
    var all: [String?] { values.withLock { $0 } }
  }

  private func client(
    _ paths: Paths,
    listing: @escaping @Sendable (String?) async throws -> DirectoryListing
  ) -> OpenCodeClient {
    var client = OpenCodeClient.testValue
    client.listDirectory = { _, path in
      paths.append(path)
      return try await listing(path)
    }
    return client
  }

  private func store(_ client: OpenCodeClient) -> TestStoreOf<FolderBrowserFeature> {
    let store = TestStore(initialState: FolderBrowserFeature.State(server: server)) {
      FolderBrowserFeature()
    } withDependencies: {
      $0.openCodeClient = client
    }
    store.exhaustivity = .off
    return store
  }

  @Test("the browser starts at the server default and reads only opened folders")
  func navigationIsRemoteAndOnDemand() async {
    let paths = Paths()
    let client = client(paths) { path in
      switch path {
      case nil:
        DirectoryListing(
          directory: "/srv",
          entries: [
            DirectoryEntry(path: "/srv/code", type: "directory"),
            DirectoryEntry(path: "/srv/readme.md", type: "file"),
          ]
        )
      case "/srv/code":
        DirectoryListing(
          directory: "/srv/code",
          entries: [DirectoryEntry(path: "/srv/code/app", type: "directory")]
        )
      default:
        DirectoryListing(directory: path ?? "/", entries: [])
      }
    }
    let store = store(client)
    await store.send(.appeared)
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(paths.all == [nil])
    guard case .loaded(let root) = store.state.listings[store.state.route] else {
      Issue.record("root did not load")
      return
    }
    #expect(root.folders == ["/srv/code"])

    await store.send(.folderTapped("/srv/code"))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(paths.all == [nil, "/srv/code"])
    guard case .loaded(let code) = store.state.listings[store.state.route] else {
      Issue.record("child did not load")
      return
    }
    #expect(code.folders == ["/srv/code/app"])
    #expect(store.state.routes.count == 2)

    await store.send(.selectTapped)
    await store.receive(.delegate(.selected("/srv/code")))
  }

  @Test("going back shows the cached parent without another read")
  func backUsesTheLoadedParent() async {
    let paths = Paths()
    let client = client(paths) { path in
      if path == nil {
        return DirectoryListing(
          directory: "/srv",
          entries: [DirectoryEntry(path: "/srv/code", type: "directory")]
        )
      }
      return DirectoryListing(directory: "/srv/code", entries: [])
    }
    let store = store(client)
    await store.send(.appeared)
    await store.send(.folderTapped("/srv/code"))
    await store.send(.backTapped)
    #expect(store.state.routes.count == 1)
    #expect(paths.all == [nil, "/srv/code"])
    #expect(store.state.canSelect)
  }

  @Test("an unreadable folder is retryable and cancel selects nothing")
  func failureAndCancel() async {
    let paths = Paths()
    let client = client(paths) { path in
      if path == nil {
        throw OpenCodeClientError(.status(403))
      }
      return DirectoryListing(directory: path ?? "/", entries: [])
    }
    let store = store(client)
    await store.send(.appeared)
    await store.finish()
    await store.skipReceivedActions(strict: false)
    guard case .failed(let error) = store.state.listings[store.state.route] else {
      Issue.record("failure was not typed")
      return
    }
    #expect(error.statusCode == 403)
    #expect(!store.state.canSelect)
    await store.send(.retryTapped)
    #expect(paths.all == [nil, nil])
  }

  @Test("selecting a folder changes a new session's project without clearing its draft")
  func sessionAppliesSelection() async {
    let server = self.server
    let selection = SessionSelection(
      serverID: server.persistenceID,
      sessionID: "new-id",
      intent: .newSession(directory: "/work/opencode")
    )
    var state = SessionFeature.State(id: 1, server: server, selection: selection)
    state.composer.draft = "Keep this draft"
    state.composer.revision = 1
    let store = TestStore(initialState: state) {
      SessionFeature()
    } withDependencies: {
      $0.openCodeClient = .testValue
      $0.clock = .testValue
      $0.networkPath = NetworkPathClient(current: { .online }, updates: { AsyncStream { $0.finish() } }, waitUntilAvailable: {})
      $0.haptics = .testValue
      $0.composerDrafts = .live(store: ComposerDraftStore(storage: InMemoryStorage(), storageKey: "drafts"))
    }
    store.exhaustivity = .off
    await store.send(.folderBrowserOpened)
    await store.send(.folderBrowser(.presented(.delegate(.selected("/work/opencode/Sources")))))
    await store.finish()
    await store.skipReceivedActions(strict: false)
    #expect(store.state.composer.target.directory == "/work/opencode/Sources")
    #expect(store.state.composer.draft == "Keep this draft")
  }

  @Test("ancestors are pure path strings and stop at the root")
  func ancestors() {
    #expect(FolderBrowserFeature.ancestors(path: "/srv/code/app") == ["/", "/srv", "/srv/code"])
    #expect(FolderBrowserFeature.ancestors(path: "/") == [])
    #expect(FolderBrowserFeature.name(path: "/srv/code/") == "code")
  }
}
