import Foundation
import OpenCodeServer

/// Why the session could not be read. Typed facts only; copy lives at the view edge.
public enum SessionProblem: Equatable, Sendable {
  case offline
  case unreachable
  case timedOut
  case credentialsRejected
  case incompatibleAPI(feature: String)
  case malformed(feature: String)
  case serverStatus(Int)
  case unsupported
  case notFound
  case unknown

  public static func from(_ error: OpenCodeClientError, isOffline: Bool = false) -> SessionProblem {
    switch error.failure {
    case .status(401): return .credentialsRejected
    case .status(404): return .notFound
    case .status(let status): return .serverStatus(status)
    case .transport(let transport):
      switch transport {
      case .timedOut: return .timedOut
      case .notSent, .interrupted: return isOffline ? .offline : .unreachable
      }
    case .invalidURL, .unsupported, .pairingExpired, .pairingUnsupported: return .unsupported
    case .undecodable(let feature): return .malformed(feature: feature)
    case .incompatibleAPI(let feature): return .incompatibleAPI(feature: feature)
    case .unreachable: return isOffline ? .offline : .unreachable
    case .streamEnded, .streamServerFailure, .streamOversizedFrame, .streamOverflow: return .unknown
    }
  }
}

/// Why an authoritative read ran. Names match the audited `RefreshReason` cases.
public enum RefreshReason: Equatable, Sendable {
  case open
  case resume
  case reconnect
  case runState
  case invalidation
  case settlement(messageID: String)
  case watchdog
  case snapshot

  public var label: String {
    switch self {
    case .open: "open"
    case .resume: "resume"
    case .reconnect: "reconnect"
    case .runState: "runState"
    case .invalidation: "invalidation"
    case .settlement: "settlement"
    case .watchdog: "watchdog"
    case .snapshot: "snapshot"
    }
  }

  public var messageID: String? {
    if case .settlement(let id) = self { return id }
    return nil
  }

  /// A content or run invalidation may have raced a read that started earlier, so it earns one
  /// follow-up. Lifecycle duplicates coalesce into the read already in flight.
  public var requiresFollowup: Bool {
    switch self {
    case .invalidation, .settlement, .runState: true
    default: false
    }
  }
}

/// The authoritative read in flight. Its id rejects the response of any read abandoned before it.
public struct SessionRefresh: Equatable, Sendable {
  public var id: Int
  public var reason: RefreshReason
  /// One newer request that may have raced this read.
  public var followup: RefreshReason?
  /// Events received while this read was in flight, replayed onto its result.
  public var racedEvents: [ServerEvent]
  /// Too many events arrived to replay them safely. The buffer is discarded and a follow-up
  /// authoritative read is required; the projection is never presented as complete.
  public var racedEventsIncomplete: Bool

  public init(
    id: Int,
    reason: RefreshReason,
    followup: RefreshReason? = nil,
    racedEvents: [ServerEvent] = [],
    racedEventsIncomplete: Bool = false
  ) {
    self.id = id
    self.reason = reason
    self.followup = followup
    self.racedEvents = racedEvents
    self.racedEventsIncomplete = racedEventsIncomplete
  }
}

public enum RequestFailure: Equatable, Sendable {
  case validation(FormValidationProblem, fieldKey: String, fieldIndex: Int)
  case reply
  case dismissal
  case settled
  case settledDismissal
  case conflict(RequestConflict)

  public var isSettled: Bool {
    switch self {
    case .settled, .settledDismissal, .conflict: true
    default: false
    }
  }
}

/// Everything one page of the request dock needs. Answers and failures are keyed by request id,
/// so they survive pushing and popping a subagent page.
public struct SessionRequests: Equatable, Sendable {
  public var permissions: [PermissionRequest]
  public var forms: [FormRequest]
  public var answers: [String: [String: FormValue]]
  public var respondingIDs: Set<String>
  public var completedIDs: Set<String>
  public var failures: [String: RequestFailure]
  public var selectedID: String?
  public var loadProblem: SessionProblem?

  public init(
    permissions: [PermissionRequest] = [],
    forms: [FormRequest] = [],
    answers: [String: [String: FormValue]] = [:],
    respondingIDs: Set<String> = [],
    completedIDs: Set<String> = [],
    failures: [String: RequestFailure] = [:],
    selectedID: String? = nil,
    loadProblem: SessionProblem? = nil
  ) {
    self.permissions = permissions
    self.forms = forms
    self.answers = answers
    self.respondingIDs = respondingIDs
    self.completedIDs = completedIDs
    self.failures = failures
    self.selectedID = selectedID
    self.loadProblem = loadProblem
  }

  public var isEmpty: Bool { permissions.isEmpty && forms.isEmpty }
  public var hasPending: Bool { !isEmpty }
  public var reviewIDs: [String] { forms.map(\.id) + permissions.map(\.id) }

  public var selectedRequestID: String? {
    if let selectedID, reviewIDs.contains(selectedID) { return selectedID }
    return reviewIDs.first
  }

  public func form(_ id: String) -> FormRequest? { forms.first { $0.id == id } }
  public func permission(_ id: String) -> PermissionRequest? { permissions.first { $0.id == id } }

  public func activeFields(_ formID: String) -> [FormField] {
    guard let form = form(formID) else { return [] }
    return form.activeFields(answers: answers[formID] ?? form.defaultAnswers)
  }

  public var selectedForm: FormRequest? {
    guard let id = selectedRequestID else { return nil }
    return form(id)
  }

  public var selectedPermission: PermissionRequest? {
    guard let id = selectedRequestID else { return nil }
    return permission(id)
  }
}

public struct SessionStopAttempt: Equatable, Sendable {
  public var steering: Set<String>
  public var acknowledged: Bool

  public init(steering: Set<String>, acknowledged: Bool = false) {
    self.steering = steering
    self.acknowledged = acknowledged
  }
}

public struct SessionRun: Equatable, Sendable {
  public var isRunning: Bool
  public var isInterrupting: Bool
  public var generation: Int
  public var stopAttempt: SessionStopAttempt?

  public init(
    isRunning: Bool = false,
    isInterrupting: Bool = false,
    generation: Int = 0,
    stopAttempt: SessionStopAttempt? = nil
  ) {
    self.isRunning = isRunning
    self.isInterrupting = isInterrupting
    self.generation = generation
    self.stopAttempt = stopAttempt
  }
}

public struct SessionPage: Equatable, Sendable, Identifiable {
  public var id: Int
  public var sessionID: String
  public var title: String
  public var parentPageID: Int?

  public init(id: Int, sessionID: String, title: String, parentPageID: Int?) {
    self.id = id
    self.sessionID = sessionID
    self.title = title
    self.parentPageID = parentPageID
  }
}

/// One shell's tailed capture. The retained window is bounded; Load Earlier can grow it to 4 MiB.
public struct ShellOutputState: Equatable, Sendable {
  public static let pageBytes = 64 * 1024
  public static let initialTailBytes = 256 * 1024
  public static let retainedBytes = 1024 * 1024
  public static let maximumRetainedBytes = 4 * 1024 * 1024

  public var shellID: String
  public var title: String
  public var output: String
  public var startCursor: Int
  public var endCursor: Int?
  public var size: Int
  public var retainLimit: Int
  public var isLoadingEarlier: Bool
  public var isStopping: Bool
  public var isRunning: Bool
  public var isUnavailable: Bool
  /// The output sheet is on screen; polling starts only when this and the initial tail are both ready.
  public var isVisible: Bool
  /// A drain could not finish; deleting now requires an explicit choice.
  public var requiresDiscardConfirmation: Bool
  public var problem: SessionProblem?

  public init(
    shellID: String,
    title: String,
    output: String = "",
    startCursor: Int = 0,
    endCursor: Int? = nil,
    size: Int = 0,
    retainLimit: Int = ShellOutputState.retainedBytes,
    isLoadingEarlier: Bool = false,
    isStopping: Bool = false,
    isRunning: Bool = true,
    isUnavailable: Bool = false,
    isVisible: Bool = false,
    requiresDiscardConfirmation: Bool = false,
    problem: SessionProblem? = nil
  ) {
    self.shellID = shellID
    self.title = title
    self.output = output
    self.startCursor = startCursor
    self.endCursor = endCursor
    self.size = size
    self.retainLimit = retainLimit
    self.isLoadingEarlier = isLoadingEarlier
    self.isStopping = isStopping
    self.isRunning = isRunning
    self.isUnavailable = isUnavailable
    self.isVisible = isVisible
    self.requiresDiscardConfirmation = requiresDiscardConfirmation
    self.problem = problem
  }

  public var isLoaded: Bool { endCursor != nil }
  public var hasEarlierOutput: Bool { startCursor > 0 }
  public var canLoadEarlier: Bool {
    hasEarlierOutput && output.utf8.count < Self.maximumRetainedBytes
  }
}

public struct SessionBackground: Equatable, Sendable {
  public var shells: [ServerShell]
  public var jobs: [ServerJob]
  public var isPresented: Bool
  public var output: ShellOutputState?
  public var stoppingIDs: Set<String>
  public var problem: SessionProblem?

  public init(
    shells: [ServerShell] = [],
    jobs: [ServerJob] = [],
    isPresented: Bool = false,
    output: ShellOutputState? = nil,
    stoppingIDs: Set<String> = [],
    problem: SessionProblem? = nil
  ) {
    self.shells = shells
    self.jobs = jobs
    self.isPresented = isPresented
    self.output = output
    self.stoppingIDs = stoppingIDs
    self.problem = problem
  }

  public var isWorking: Bool { !shells.isEmpty || !jobs.isEmpty }
}

public enum SessionNotice: Equatable, Sendable {
  case couldNotRefresh(SessionProblem)
  case couldNotLoadFamily(SessionProblem)
  case couldNotLoadRequests(SessionProblem)
  case couldNotInterrupt
  case couldNotStopShell
  case couldNotLoadOutput
  case couldNotCancelJob
  case couldNotWakeInput
  case sessionGone
}
