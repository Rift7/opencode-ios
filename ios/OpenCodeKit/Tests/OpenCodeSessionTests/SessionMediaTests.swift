import ComposableArchitecture
import Foundation
import OpenCodeCore
import OpenCodeMedia
import OpenCodeServer
import OpenCodeSession
import OpenCodeTestSupport
import Testing

@MainActor
@Suite("Session media", .serialized)
struct SessionMediaTests {
  actor Calls {
    var interrupts: [String] = []
    var cancelledJobs: [String] = []
    var opened: [String] = []

    func interrupt(_ id: String) { interrupts.append(id) }
    func cancel(_ id: String) { cancelledJobs.append(id) }
    func open(_ url: String) { opened.append(url) }
  }

  func server() -> OpenCodeServer {
    OpenCodeServer(url: "https://wire-00000000-0000-4000-8000-000000000000.invalid", password: "test")
  }

  func session(id: String, parent: String? = nil) -> OpenCodeSession {
    OpenCodeSession(
      id: id,
      serverTitle: id,
      projectID: "p1",
      directory: "/work/app",
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
      parentID: parent
    )
  }

  func state() -> SessionFeature.State {
    let server = server()
    var state = SessionFeature.State(
      id: 1,
      server: server,
      selection: SessionSelection(serverID: server.persistenceID, sessionID: "alpha", intent: .browse),
      session: session(id: "alpha")
    )
    state.family = SessionFamily(
      root: session(id: "alpha"),
      sessions: [session(id: "alpha"), session(id: "child", parent: "alpha")],
      activeSessionIDs: ["child"]
    )
    return state
  }

  func image(id: String, hash: String) -> TranscriptImage {
    TranscriptImage(
      id: id,
      mediaHash: hash,
      name: "image.png",
      mime: "image/png",
      pixelWidth: 100,
      pixelHeight: 50
    )
  }

  @Test("tapping a transcript image presents the gallery at that image")
  func imageGalleryPresentation() async {
    let store = TestStore(initialState: state()) {
      SessionFeature()
    } withDependencies: {
      $0.haptics = .testValue
      $0.mediaImages = .testValue
    }
    store.exhaustivity = .off
    let hash = String(repeating: "a", count: 64)
    let images = [image(id: "one", hash: hash), image(id: "two", hash: String(repeating: "b", count: 64))]
    await store.send(.transcriptImagesTapped(images, 1)) {
      $0.mediaViewer = MediaViewerFeature.State(
        pages: [
          MediaViewerPage(
            id: "one",
            title: "image.png",
            detail: "image/png",
            kind: .image,
            source: .mediaHash(hash),
            canAnnotate: true,
            pixelWidth: 100,
            pixelHeight: 50
          ),
          MediaViewerPage(
            id: "two",
            title: "image.png",
            detail: "image/png",
            kind: .image,
            source: .mediaHash(String(repeating: "b", count: 64)),
            canAnnotate: true,
            pixelWidth: 100,
            pixelHeight: 50
          ),
        ],
        index: 1,
        server: self.server()
      )
    }
    #expect(store.state.mediaViewer?.page?.id == "two")
  }

  @Test("a file card presents the server file viewer with the session folder")
  func fileViewerPresentation() async {
    let store = TestStore(initialState: state()) {
      SessionFeature()
    } withDependencies: {
      $0.haptics = .testValue
    }
    store.exhaustivity = .off
    let file = TranscriptFile(id: "f", name: "main.swift", mime: "text/plain", path: "Sources/main.swift")
    await store.send(.transcriptFileTapped(file)) {
      $0.fileViewer = FileViewerFeature.State(
        file: file,
        server: self.server(),
        directory: "/work/app"
      )
    }
    #expect(store.state.fileViewer?.directory == "/work/app")
    #expect(store.state.fileViewer?.file.path == "Sources/main.swift")
  }

  @Test("stopping a background subagent interrupts the child and cancels its jobs")
  func subagentStop() async {
    let calls = Calls()
    var client = OpenCodeClient.testValue
    client.interruptSession = { _, id in
      await calls.interrupt(id)
      return true
    }
    client.cancelJob = { _, id in
      await calls.cancel(id)
    }
    var initial = state()
    initial.background.jobs = [
      ServerJob(id: "job-child", kind: .subagent, sessionID: "alpha", isRunning: true, childSessionID: "child"),
      ServerJob(id: "job-root", kind: .codemode, sessionID: "alpha", isRunning: true),
    ]
    let store = TestStore(initialState: initial) {
      SessionFeature()
    } withDependencies: {
      $0.openCodeClient = client
      $0.haptics = .testValue
    }
    store.exhaustivity = .off
    await store.send(.backgroundSubagentStopTapped("child")) {
      $0.background.stoppingIDs = ["child"]
    }
    await store.receive(.backgroundSubagentStopFinished("child", failed: false)) {
      $0.background.stoppingIDs = []
      $0.background.jobs.removeAll { $0.id == "job-child" }
    }
    #expect(await calls.interrupts == ["child"])
    #expect(await calls.cancelledJobs == ["job-child"])
    #expect(store.state.background.jobs.map(\.id) == ["job-root"])
  }

  @Test("the browser experiment gates a public link; off opens the system browser")
  func browserGate() async {
    let calls = Calls()
    var initial = state()
    initial.pendingLink = URL(string: "https://example.com/docs")
    let off = TestStore(initialState: initial) {
      SessionFeature()
    } withDependencies: {
      $0.haptics = .testValue
      $0.mediaExperiments = MediaExperiments(inAppBrowser: { false })
      $0.linkOpener = OpenURLClient { url in
        await calls.open(url.absoluteString)
        return true
      }
    }
    off.exhaustivity = .off
    await off.send(.transcriptLinkConfirmed) { $0.pendingLink = nil }
    #expect(await calls.opened == ["https://example.com/docs"])
    #expect(off.state.browser == nil)

    let on = TestStore(initialState: initial) {
      SessionFeature()
    } withDependencies: {
      $0.haptics = .testValue
      $0.mediaExperiments = MediaExperiments(inAppBrowser: { true })
    }
    on.exhaustivity = .off
    await on.send(.transcriptLinkConfirmed)
    #expect(on.state.browser?.url == "https://example.com/docs")
    await on.send(.browserClosed) { $0.browser = nil }
    #expect(on.state.browser == nil)
  }
}
