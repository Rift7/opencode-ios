import ComposableArchitecture
import Foundation
import OpenCodeCore
import OpenCodeServer
import OpenCodeSettings
import OpenCodeTestSupport
import Testing

@MainActor
@Suite("Settings", .serialized)
struct SettingsFeatureTests {
  private let server = OpenCodeServer(
    url: "http://10.0.0.2:4096",
    username: "opencode",
    password: "synthetic-token",
    headers: [.init(name: "CF-Access-Client-Id", value: "synthetic-id")]
  )

  private func store(
    defaults: any KeyValueStorage = InMemoryStorage(),
    state: SettingsFeature.State = SettingsFeature.State()
  ) -> TestStoreOf<SettingsFeature> {
    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0.sharedStore = SharedStore(defaults: defaults, keychain: InMemoryStorage())
      $0.dateClient = DateClient { Date(timeIntervalSince1970: 1_700_000_000) }
      $0.pasteboard = PasteboardClient(string: { nil }, setString: { _ in })
      $0.pairingScanner = .testValue
    }
    store.exhaustivity = .off
    return store
  }

  @Test("fresh preferences are the documented defaults")
  func defaults() {
    let read = SettingsFeature.readPreferences(
      SharedStore(defaults: InMemoryStorage(), keychain: InMemoryStorage())
    )
    #expect(read.preferences == SettingsPreferences())
    #expect(read.problem == nil)
  }

  @Test("a delayed restore never overwrites a newer choice")
  func restoreDoesNotOverwriteAnEdit() async {
    let store = store()
    await store.send(.preferencesLoaded(SettingsPreferences(), problem: nil))
    await store.send(.appearanceChanged(.dark))
    #expect(store.state.preferences.appearance == .dark)
    await store.send(
      .preferencesLoaded(
        SettingsPreferences(appearance: .light, returnKeySends: true, inAppBrowser: true),
        problem: nil
      )
    )
    #expect(store.state.preferences.appearance == .dark)
    #expect(store.state.preferences.returnKeySends == true)
    #expect(store.state.preferences.inAppBrowser == true)
  }

  @Test("a failed write is reported and is not presented as saved")
  func failedPreferenceWrite() async {
    let store = store(defaults: FailingStorage(failure: .denied))
    await store.send(.appearanceChanged(.dark))
    #expect(store.state.preferences.appearance == .system)
    #expect(store.state.saveProblem == .appearance)
    #expect(store.state.preferencesProblem == .storage(.denied))
  }

  @Test("turning the browser experiment off reaches the session")
  func browserExperimentChanged() async {
    let store = store()
    await store.send(.inAppBrowserChanged(true))
    await store.receive(.delegate(.inAppBrowserChanged(true)))
    #expect(store.state.preferences.inAppBrowser)
  }

  @Test("header names, values and transport-owned fields are refused")
  func headerPolicy() {
    #expect(OpenCodeServer.Header(name: "", value: "x").problem == .emptyName)
    #expect(OpenCodeServer.Header(name: "Bad Header", value: "x").problem == .invalidName)
    #expect(OpenCodeServer.Header(name: "X-Test", value: "a\r\nInjected: yes").problem == .invalidValue)
    for name in ["Authorization", "Host", "Content-Length", "Transfer-Encoding", "Connection"] {
      #expect(OpenCodeServer.Header(name: name, value: "x").problem == .forbiddenName)
    }
    var form = ServerEditForm(server)
    form.headers = [.init(name: "CF-Access-Client-Id", value: "synthetic-id")]
    #expect(form.validate() != nil)
    form.headers = [.init(name: "Bad Header", value: "x")]
    #expect(form.validate() == nil)
    #expect(form.headerProblem == .invalidName(index: 0, name: "Bad Header"))
  }

  @Test("an invalid form keeps the prior usable configuration")
  func invalidFormKeepsPriorServer() async {
    var state = SettingsFeature.State(server: server)
    state.serverForm = ServerEditForm(server)
    let store = store(state: state)
    await store.send(.serverHeaderAdded)
    await store.send(.serverFormSubmitted)
    #expect(store.state.server == server)
    #expect(store.state.serverForm?.headerProblem == .emptyName(index: 1))
    #expect(store.state.serverForm?.original == server)
  }

  @Test("a server save failure keeps the old server and the edits")
  func saveFailureKeepsPriorServer() async {
    var state = SettingsFeature.State(server: server)
    var form = ServerEditForm(server)
    form.address = "http://10.0.0.3:4096"
    state.serverForm = form
    let store = store(state: state)
    await store.send(.serverFormSubmitted)
    let operationID = store.state.serverFormOperation!
    await store.send(
      .serverSaveResult(operationID: operationID, previous: server, result: .failure(.denied))
    )
    #expect(store.state.server == server)
    #expect(store.state.serverForm?.address == "http://10.0.0.3:4096")
    #expect(store.state.serverFormSaveProblem == .storage(.denied))
  }

  @Test("duplicate submissions and late results cannot overwrite a newer edit")
  func serverWriteFencing() async {
    var state = SettingsFeature.State(server: server)
    var form = ServerEditForm(server)
    form.address = "http://10.0.0.3:4096"
    state.serverForm = form
    let store = store(state: state)

    await store.send(.serverFormSubmitted)
    let first = store.state.serverFormOperation!
    await store.send(.serverFormSubmitted)
    #expect(store.state.serverFormOperation == first)

    await store.send(
      .serverSaveResult(
        operationID: UUID(),
        previous: server,
        result: .success(server)
      )
    )
    #expect(store.state.serverFormOperation == first)
    await store.send(
      .serverSaveResult(operationID: first, previous: server, result: .success(server))
    )
    #expect(store.state.serverFormOperation == nil)
    #expect(store.state.server == server)
  }

  @Test("an unavailable or corrupt appearance read is reported")
  func appearanceStorageProblem() {
    let unavailable = SettingsFeature.readPreferences(
      OpenCodeCore.SharedStore(
        defaults: FailingStorage(failure: .denied),
        keychain: OpenCodeCore.InMemoryStorage()
      )
    )
    #expect(unavailable.problem == .storage(.denied))
    #expect(unavailable.preferences.appearance == .system)

    let corruptDefaults = OpenCodeCore.InMemoryStorage()
    _ = corruptDefaults.write(Data("not json".utf8), for: SharedKeys.appearanceColorScheme.name)
    let corrupt = SettingsFeature.readPreferences(
      OpenCodeCore.SharedStore(
        defaults: corruptDefaults,
        keychain: OpenCodeCore.InMemoryStorage()
      )
    )
    #expect(corrupt.problem == .corrupt)
    #expect(corrupt.preferences.appearance == .system)
  }

  @Test("diagnostics contain typed facts and no synthetic secret")
  func diagnosticsPrivacy() {
    let facts = DiagnosticFacts(
      appVersion: "1.0",
      build: "7",
      phase: .failed,
      failure: .credentialsRejected,
      statusCode: 401,
      savedServers: 2,
      projects: 3,
      sessions: 12,
      transcriptRows: 48,
      drafts: 1,
      activeRequests: 2
    )
    let report = DiagnosticReport(facts: facts, generatedAt: Date(timeIntervalSince1970: 1_700_000_000))
    #expect(report.text.contains("Phase: failed"))
    #expect(report.text.contains("HTTP status: 401"))
    #expect(report.text.contains("Sessions: 12"))
    for secret in [
      "synthetic-token", "CF-Access-Client-Id", "synthetic-id", "10.0.0.2",
      "pairing", "message text", "/work/opencode", "Bearer", "Basic",
    ] {
      #expect(!report.text.localizedCaseInsensitiveContains(secret))
    }
  }

  @Test("onboarding can finish without a server or credentials")
  func onboardingFinishesOffline() async {
    let storage: OpenCodeCore.InMemoryStorage = .init()
    let store = store(defaults: storage)
    await store.send(.onboardingNext)
    await store.send(.onboardingNext)
    #expect(store.state.onboardingStep == 2)
    await store.send(.onboardingFinished)
    #expect(store.state.preferences.onboardingCompleted)
    #expect(store.state.notice == .onboardingFinished)
    let shared = OpenCodeCore.SharedStore(defaults: storage, keychain: OpenCodeCore.InMemoryStorage())
    if case .value(let completed) = shared.read(SharedKeys.onboardingCompleted) {
      #expect(completed)
    } else {
      Issue.record("onboarding completion was not written")
    }
  }

  @Test("a scanned payload is forwarded once and never redeemed by the scanner")
  func scanIsForwardedExactlyOnce() async {
    var state = SettingsFeature.State(isScanning: true, scanGeneration: 1)
    state.isPresented = true
    let store = store(state: state)
    await store.send(.scanEvent(.code("opencode://pair?code=synthetic"), generation: 1))
    await store.receive(.delegate(.pairingPayload("opencode://pair?code=synthetic")))
    #expect(!store.state.isScanning)
    #expect(store.state.handledScans.count == 1)

    await store.send(.scanEvent(.code("opencode://pair?code=synthetic"), generation: 1))
    #expect(store.state.handledScans.count == 1)
  }

  @Test("camera denial is a typed, retryable outcome")
  func cameraDenied() async {
    let store = store(state: SettingsFeature.State(isScanning: true, scanGeneration: 1))
    await store.send(.scanEvent(.denied, generation: 1))
    #expect(store.state.scanProblem == .cameraDenied)
    #expect(!store.state.isScanning)
    #expect(store.state.isScanPresented)

    await store.send(.scanProblemDismissed)
    #expect(store.state.scanProblem == nil)
    #expect(!store.state.isScanPresented)
  }

  @Test("cancelling a camera problem closes the scanner cover")
  func cameraProblemCancelDismisses() async {
    let store = store(state: SettingsFeature.State(isScanning: true, scanGeneration: 1))
    await store.send(.scanEvent(.denied, generation: 1))
    #expect(store.state.isScanPresented)

    await store.send(.scanCancelled)
    #expect(store.state.scanProblem == nil)
    #expect(!store.state.isScanning)
    #expect(!store.state.isScanPresented)
  }

  @Test("the injected deep link is a valid pairing payload")
  func injectedPairingPayloadDecodes() {
    let payload = "opencode-ios://pair?code=Pair-123_xyz&url=https%3A%2F%2Fstudio.invalid"
    let link = PairingLink.decodeCopied(payload)
    #expect(link?.code == "Pair-123_xyz")
    #expect(link?.origin == "https://studio.invalid")
  }

  @Test("a custom header change starts a new media cache scope")
  func headerChangeInvalidatesAuthenticationScope() {
    let plain = OpenCodeServer(url: "https://box.example", password: "token")
    var withHeader = plain
    withHeader.headers = [.init(name: "CF-Access-Client-Secret", value: "synthetic")]
    #expect(plain.authenticationScopeMaterial != withHeader.authenticationScopeMaterial)
    #expect(withHeader.wireHeaders["Authorization"] != nil)
    #expect(withHeader.wireHeaders["CF-Access-Client-Secret"] == "synthetic")
  }
}
