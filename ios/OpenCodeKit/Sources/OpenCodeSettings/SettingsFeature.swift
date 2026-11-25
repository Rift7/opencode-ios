import ComposableArchitecture
import Foundation
import OpenCodeCore
import OpenCodeServer

/// Settings' navigation, typed preferences, server editing, diagnostics, onboarding and the
/// camera-scan boundary. Connection, pairing redemption and credential persistence stay with the
/// app shell: this reducer asks for those through delegates.
@Reducer
public struct SettingsFeature: Sendable {
  @ObservableState
  public struct State: Equatable, Sendable {
    public var isPresented: Bool
    public var path: [SettingsPage]
    public var server: OpenCodeServer?
    public var preferences: SettingsPreferences
    public var preferencesProblem: PreferencesProblem?
    public var saveProblem: SettingsPreference?
    public var serverForm: ServerEditForm?
    public var serverFormOperation: UUID?
    public var serverFormSaveProblem: PreferencesProblem?
    public var pendingRemoval: OpenCodeServer?
    public var removalProblem: ServerRemovalProblem?
    public var diagnosticsFacts: DiagnosticFacts?
    public var diagnosticsReport: DiagnosticReport?
    public var diagnosticsCopied: Bool
    public var onboardingStep: Int
    public var isScanning: Bool
    public var scanProblem: PairingScanProblem?
    /// Set when the setup screen opens Settings only to scan; the first task starts the scanner.
    public var scanOnOpen: Bool
    /// The scanner cover remains presented while a typed problem is shown, so a denial is visible
    /// instead of dismissing the cover with the scan.
    public var isScanPresented: Bool { isScanning || scanProblem != nil }
    public var handledScans: Set<String>
    public var notice: SettingsNotice?

    var edited: Set<SettingsPreference>
    var didStart: Bool
    var scanGeneration: Int

    public init(
      isPresented: Bool = false,
      path: [SettingsPage] = [],
      server: OpenCodeServer? = nil,
      preferences: SettingsPreferences = SettingsPreferences(),
      preferencesProblem: PreferencesProblem? = nil,
      saveProblem: SettingsPreference? = nil,
      serverForm: ServerEditForm? = nil,
      serverFormOperation: UUID? = nil,
      serverFormSaveProblem: PreferencesProblem? = nil,
      pendingRemoval: OpenCodeServer? = nil,
      removalProblem: ServerRemovalProblem? = nil,
      diagnosticsFacts: DiagnosticFacts? = nil,
      diagnosticsReport: DiagnosticReport? = nil,
      diagnosticsCopied: Bool = false,
      onboardingStep: Int = 0,
      isScanning: Bool = false,
      scanProblem: PairingScanProblem? = nil,
      scanOnOpen: Bool = false,
      handledScans: Set<String> = [],
      notice: SettingsNotice? = nil,
      edited: Set<SettingsPreference> = [],
      didStart: Bool = false,
      scanGeneration: Int = 0
    ) {
      self.isPresented = isPresented
      self.path = path
      self.server = server
      self.preferences = preferences
      self.preferencesProblem = preferencesProblem
      self.saveProblem = saveProblem
      self.serverForm = serverForm
      self.serverFormOperation = serverFormOperation
      self.serverFormSaveProblem = serverFormSaveProblem
      self.pendingRemoval = pendingRemoval
      self.removalProblem = removalProblem
      self.diagnosticsFacts = diagnosticsFacts
      self.diagnosticsReport = diagnosticsReport
      self.diagnosticsCopied = diagnosticsCopied
      self.onboardingStep = onboardingStep
      self.isScanning = isScanning
      self.scanProblem = scanProblem
      self.scanOnOpen = scanOnOpen
      self.handledScans = handledScans
      self.notice = notice
      self.edited = edited
      self.didStart = didStart
      self.scanGeneration = scanGeneration
    }

    public var page: SettingsPage? { path.last }

    public var isAtRoot: Bool { path.isEmpty }

    /// Editing is refused while the saved list itself is unreadable; the shell shows its own
    /// replace action rather than letting Settings write over unknown credentials.
    public var canEditServers: Bool { server != nil }
  }

  public enum SettingsNotice: Equatable, Sendable {
    case couldNotCopy
    case serverRemoved
    case onboardingFinished
  }

  public enum Action: Equatable, Sendable {
    case task
    case preferencesLoaded(SettingsPreferences, problem: PreferencesProblem?)
    case appearanceChanged(AppearanceChoice)
    case returnKeySendsChanged(Bool)
    case fileViewerWrapChanged(Bool)
    case inAppBrowserChanged(Bool)
    case saveProblemDismissed

    case opened
    case closed
    case pagePushed(SettingsPage)
    case pathReplaced([SettingsPage])
    case backTapped

    case serverEditTapped
    case serverFormNameChanged(String)
    case serverFormAddressChanged(String)
    case serverFormUsernameChanged(String)
    case serverFormPasswordChanged(String)
    case serverHeaderNameChanged(index: Int, name: String)
    case serverHeaderValueChanged(index: Int, value: String)
    case serverHeaderAdded
    case serverHeaderRemoved(index: Int)
    case serverFormSubmitted
    case serverFormDismissed
    case serverSaveResult(
      operationID: UUID,
      previous: OpenCodeServer,
      result: Result<OpenCodeServer, StorageFailure>
    )
    case serverRemoveTapped
    case serverRemoveCancelled
    case serverRemoveConfirmed
    case serverForgetResult(server: OpenCodeServer, result: ServerForgetResult)
    case removalProblemDismissed

    case diagnosticsContextChanged(DiagnosticFacts)
    case diagnosticsRequested
    case diagnosticsCopyTapped
    case diagnosticsCopied(Bool)

    case onboardingNext
    case onboardingBack
    case onboardingFinished

    case scanTapped
    case scanEvent(PairingScanEvent, generation: Int)
    case scanCancelled
    case scanProblemDismissed

    case noticeDismissed
    case delegate(Delegate)
  }

  public enum Delegate: Equatable, Sendable {
    case close
    case saveServer(operationID: UUID, previous: OpenCodeServer, updated: OpenCodeServer)
    case forgetServer(OpenCodeServer)
    case pairingPayload(String)
    case inAppBrowserChanged(Bool)
    case preferencesChanged(SettingsPreferences)
  }

  enum CancelID: Hashable {
    case scan
  }

  @Dependency(\.sharedStore) private var store
  @Dependency(\.dateClient) private var date
  @Dependency(\.pasteboard) private var pasteboard
  @Dependency(\.pairingScanner) private var scanner

  public init() {}

  public var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .task:
        guard !state.didStart else { return .none }
        state.didStart = true
        let result = Self.readPreferences(store)
        return .send(.preferencesLoaded(result.preferences, problem: result.problem))

      case .preferencesLoaded(let loaded, let problem):
        // A delayed read may fill fields the person has not touched, but never overwrite a choice
        // made while it was in flight.
        if !state.edited.contains(.appearance) { state.preferences.appearance = loaded.appearance }
        if !state.edited.contains(.returnKeySends) { state.preferences.returnKeySends = loaded.returnKeySends }
        if !state.edited.contains(.fileViewerWrapsLines) {
          state.preferences.fileViewerWrapsLines = loaded.fileViewerWrapsLines
        }
        if !state.edited.contains(.inAppBrowser) { state.preferences.inAppBrowser = loaded.inAppBrowser }
        if !state.edited.contains(.onboardingCompleted) {
          state.preferences.onboardingCompleted = loaded.onboardingCompleted
        }
        state.preferencesProblem = problem
        return .none

      case .appearanceChanged(let choice):
        let before = state.preferences
        let write = savePreference(.appearance, choice, state: &state, write: {
          store.write(choice.rawValue, for: SharedKeys.appearanceColorScheme)
        }) { state, value in
          state.preferences.appearance = value
        }
        return preferencesEffect(before: before, write: write, state: state)

      case .returnKeySendsChanged(let enabled):
        let before = state.preferences
        let write = savePreference(.returnKeySends, enabled, state: &state, write: {
          store.write(enabled, for: SharedKeys.returnKeySends)
        }) { state, value in
          state.preferences.returnKeySends = value
        }
        return preferencesEffect(before: before, write: write, state: state)

      case .fileViewerWrapChanged(let enabled):
        let before = state.preferences
        let write = savePreference(.fileViewerWrapsLines, enabled, state: &state, write: {
          store.write(enabled, for: SharedKeys.fileViewerWrapsLines)
        }) { state, value in
          state.preferences.fileViewerWrapsLines = value
        }
        return preferencesEffect(before: before, write: write, state: state)

      case .inAppBrowserChanged(let enabled):
        let before = state.preferences
        let write = savePreference(.inAppBrowser, enabled, state: &state, write: {
          store.write(enabled, for: SharedKeys.experimentalInAppBrowser)
        }) { state, value in
          state.preferences.inAppBrowser = value
        }
        guard state.preferences.inAppBrowser == enabled else { return write }
        return .merge(
          preferencesEffect(before: before, write: write, state: state),
          enabled == before.inAppBrowser ? .none : .send(.delegate(.inAppBrowserChanged(enabled)))
        )

      case .saveProblemDismissed:
        state.saveProblem = nil
        return .none

      case .opened:
        state.isPresented = true
        return .send(.task)

      case .closed:
        state.isPresented = false
        state.path.removeAll()
        state.serverForm = nil
        state.serverFormOperation = nil
        state.pendingRemoval = nil
        state.scanProblem = nil
        state.isScanning = false
        state.scanOnOpen = false
        return .merge(.cancel(id: CancelID.scan), stopScanner())

      case .pagePushed(let page):
        state.path.append(page)
        return .none

      case .pathReplaced(let path):
        state.path = path
        return .none

      case .backTapped:
        if state.serverForm != nil {
          state.serverForm = nil
          return .none
        }
        if state.pendingRemoval != nil {
          state.pendingRemoval = nil
          return .none
        }
        if state.isScanning {
          state.isScanning = false
          return .merge(.cancel(id: CancelID.scan), stopScanner())
        }
        if !state.path.isEmpty {
          state.path.removeLast()
          return .none
        }
        state.isPresented = false
        return .send(.delegate(.close))

      case .serverEditTapped:
        guard let server = state.server else { return .none }
        state.serverForm = ServerEditForm(server)
        state.serverFormSaveProblem = nil
        state.path.append(SettingsPage(kind: .server, serverID: server.persistenceID))
        return .none

      case .serverFormNameChanged(let value):
        state.serverForm?.name = value
        state.serverForm?.problem = nil
        return .none

      case .serverFormAddressChanged(let value):
        state.serverForm?.address = value
        state.serverForm?.problem = nil
        return .none

      case .serverFormUsernameChanged(let value):
        state.serverForm?.username = value
        return .none

      case .serverFormPasswordChanged(let value):
        state.serverForm?.password = value
        return .none

      case .serverHeaderNameChanged(let index, let name):
        guard var form = state.serverForm, form.headers.indices.contains(index) else { return .none }
        form.headers[index].name = name
        form.headerProblem = nil
        state.serverForm = form
        return .none

      case .serverHeaderValueChanged(let index, let value):
        guard var form = state.serverForm, form.headers.indices.contains(index) else { return .none }
        form.headers[index].value = value
        form.headerProblem = nil
        state.serverForm = form
        return .none

      case .serverHeaderAdded:
        guard var form = state.serverForm, form.headers.count < 16 else { return .none }
        form.headers.append(.init(name: "", value: ""))
        state.serverForm = form
        return .none

      case .serverHeaderRemoved(let index):
        guard var form = state.serverForm, form.headers.indices.contains(index) else { return .none }
        form.headers.remove(at: index)
        form.headerProblem = nil
        state.serverForm = form
        return .none

      case .serverFormSubmitted:
        guard state.serverFormOperation == nil else { return .none }
        guard var form = state.serverForm else { return .none }
        guard let updated = form.validate() else {
          state.serverForm = form
          return .none
        }
        state.serverForm = form
        let previous = form.original
        let operationID = UUID()
        state.serverFormOperation = operationID
        state.serverFormSaveProblem = nil
        return .send(
          .delegate(.saveServer(operationID: operationID, previous: previous, updated: updated))
        )

      case .serverFormDismissed:
        state.serverForm = nil
        state.serverFormOperation = nil
        state.serverFormSaveProblem = nil
        if state.page?.kind == .server { state.path.removeLast() }
        return .none

      case .serverSaveResult(let operationID, let previous, let result):
        guard state.serverFormOperation == operationID,
          let form = state.serverForm,
          form.original == previous
        else { return .none }
        state.serverFormOperation = nil
        switch result {
        case .success(let saved):
          state.server = saved
          state.serverForm = nil
          state.serverFormSaveProblem = nil
          if state.page?.kind == .server { state.path.removeLast() }
        case .failure(let failure):
          // Keep the saved record and the person's edits; nothing was presented as saved.
          state.server = previous
          state.serverFormSaveProblem = .storage(failure)
        }
        return .none

      case .serverRemoveTapped:
        guard let server = state.server else { return .none }
        state.pendingRemoval = server
        state.removalProblem = nil
        return .none

      case .serverRemoveCancelled:
        state.pendingRemoval = nil
        return .none

      case .serverRemoveConfirmed:
        guard let server = state.pendingRemoval else { return .none }
        state.pendingRemoval = nil
        return .send(.delegate(.forgetServer(server)))

      case .serverForgetResult(let forgotten, let result):
        guard state.server == forgotten else { return .none }
        switch result {
        case .removed:
          state.server = nil
          state.path.removeAll()
          state.notice = .serverRemoved
        case .failure(let failure):
          state.removalProblem = .storage(failure)
        }
        return .none

      case .removalProblemDismissed:
        state.removalProblem = nil
        return .none

      case .diagnosticsContextChanged(let facts):
        if state.diagnosticsFacts != facts {
          state.diagnosticsFacts = facts
          state.diagnosticsCopied = false
        }
        return .none

      case .diagnosticsRequested:
        guard let facts = state.diagnosticsFacts else { return .none }
        state.diagnosticsReport = DiagnosticReport(facts: facts, generatedAt: date.now())
        state.diagnosticsCopied = false
        return .none

      case .diagnosticsCopyTapped:
        guard let report = state.diagnosticsReport ?? state.diagnosticsFacts.map({
          DiagnosticReport(facts: $0, generatedAt: date.now())
        }) else { return .none }
        state.diagnosticsReport = report
        let pasteboard = pasteboard
        return .run { send in
          pasteboard.setString(report.text)
          await send(.diagnosticsCopied(true))
        }

      case .diagnosticsCopied(let copied):
        state.diagnosticsCopied = copied
        if !copied { state.notice = .couldNotCopy }
        return .none

      case .onboardingNext:
        state.onboardingStep = min(2, state.onboardingStep + 1)
        return .none

      case .onboardingBack:
        state.onboardingStep = max(0, state.onboardingStep - 1)
        return .none

      case .onboardingFinished:
        state.preferences.onboardingCompleted = true
        state.edited.insert(.onboardingCompleted)
        let write = store.write(true, for: SharedKeys.onboardingCompleted)
        if case .failure(let failure) = write {
          state.preferences.onboardingCompleted = false
          state.saveProblem = .onboardingCompleted
          state.preferencesProblem = .storage(failure)
          return .none
        }
        state.notice = .onboardingFinished
        return .none

      case .scanTapped:
        guard !state.isScanning else { return .none }
        state.scanGeneration += 1
        let generation = state.scanGeneration
        state.isScanning = true
        state.scanOnOpen = false
        state.scanProblem = nil
        let scanner = scanner
        return .run { send in
          let events = await scanner.start()
          for await event in events {
            await send(.scanEvent(event, generation: generation))
          }
        }
        .cancellable(id: CancelID.scan, cancelInFlight: true)

      case .scanEvent(let event, let generation):
        guard state.isScanning, generation == state.scanGeneration else { return .none }
        switch event {
        case .code(let payload):
          guard !payload.isEmpty, state.handledScans.insert(payload).inserted else { return .none }
          state.isScanning = false
          return .merge(
            .cancel(id: CancelID.scan),
            stopScanner(),
            .send(.delegate(.pairingPayload(payload)))
          )
        case .denied:
          state.scanProblem = .cameraDenied
        case .restricted:
          state.scanProblem = .cameraRestricted
        case .unavailable:
          state.scanProblem = .cameraUnavailable
        case .failed:
          state.scanProblem = .cameraFailed
        }
        state.isScanning = false
        return .merge(.cancel(id: CancelID.scan), stopScanner())

      case .scanCancelled:
        guard state.isScanning || state.scanProblem != nil else { return .none }
        state.isScanning = false
        state.scanProblem = nil
        state.scanGeneration += 1
        return .merge(.cancel(id: CancelID.scan), stopScanner())

      case .scanProblemDismissed:
        state.scanProblem = nil
        return .none

      case .noticeDismissed:
        state.notice = nil
        return .none

      case .delegate:
        return .none
      }
    }
  }

  private func preferencesEffect(
    before: SettingsPreferences,
    write: Effect<Action>,
    state: State
  ) -> Effect<Action> {
    guard state.preferences != before else { return write }
    return .merge(write, .send(.delegate(.preferencesChanged(state.preferences))))
  }

  private func savePreference<Value>(
    _ preference: SettingsPreference,
    _ value: Value,
    state: inout State,
    write: () -> StorageWrite,
    apply: (inout State, Value) -> Void
  ) -> Effect<Action> {
    let writeResult = write()
    switch writeResult {
    case .success:
      apply(&state, value)
      state.edited.insert(preference)
      if state.saveProblem == preference { state.saveProblem = nil }
      return .none
    case .failure(let failure):
      state.preferencesProblem = .storage(failure)
      state.saveProblem = preference
      return .none
    }
  }

  private func stopScanner() -> Effect<Action> {
    let scanner = scanner
    return .run { _ in scanner.stop() }
  }

  public static func readPreferences(
    _ store: SharedStore
  ) -> (preferences: SettingsPreferences, problem: PreferencesProblem?) {
    func read<Value>(
      _ key: OpenCodeCore.SharedKey<Value>,
      _ fallback: Value
    ) -> (Value, PreferencesProblem?) {
      switch store.read(key) {
      case .value(let value): return (value, nil)
      case .missing: return (key.defaultValue, nil)
      case .undecodable: return (fallback, .corrupt)
      case .failure(let failure): return (fallback, .storage(failure))
      }
    }

    var problem: PreferencesProblem?
    var appearance = AppearanceChoice.system
    let appearanceRead = read(SharedKeys.appearanceColorScheme, "system")
    if let issue = appearanceRead.1 { problem = issue }
    let appearanceValue = appearanceRead.0
    if let parsed = AppearanceChoice(rawValue: appearanceValue) {
      appearance = parsed
    } else if !appearanceValue.isEmpty, problem == nil {
      problem = .corrupt
    }
    let returnKey = read(SharedKeys.returnKeySends, false)
    if let issue = returnKey.1 { problem = issue }
    let wraps = read(SharedKeys.fileViewerWrapsLines, false)
    if let issue = wraps.1 { problem = issue }
    let browser = read(SharedKeys.experimentalInAppBrowser, false)
    if let issue = browser.1 { problem = issue }
    let onboarding = read(SharedKeys.onboardingCompleted, false)
    if let issue = onboarding.1 { problem = issue }
    return (
      SettingsPreferences(
        appearance: appearance,
        returnKeySends: returnKey.0,
        fileViewerWrapsLines: wraps.0,
        inAppBrowser: browser.0,
        onboardingCompleted: onboarding.0
      ),
      problem
    )
  }
}

extension PairingScannerClient: DependencyKey {
  public static var liveValue: PairingScannerClient {
    #if canImport(AVFoundation) && os(iOS)
      return PairingScannerClient(
        start: { await QRCameraScanner.shared.events() },
        stop: { Task { @MainActor in QRCameraScanner.shared.stopScanning() } }
      )
    #else
      return PairingScannerClient(start: {
        AsyncStream { continuation in
          continuation.yield(.unavailable)
          continuation.finish()
        }
      })
    #endif
  }

  public static let testValue = PairingScannerClient(start: {
    AsyncStream { $0.finish() }
  })
}

extension DependencyValues {
  public var pairingScanner: PairingScannerClient {
    get { self[PairingScannerClient.self] }
    set { self[PairingScannerClient.self] = newValue }
  }
}
