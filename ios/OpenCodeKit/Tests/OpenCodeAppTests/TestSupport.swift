import Foundation
import OpenCodeCore
import OpenCodeServer
import Synchronization

enum TestServer {
  static let server = OpenCodeServer(
    url: "http://127.0.0.1:4110",
    username: "opencode",
    password: "test-token"
  )
  static let other = OpenCodeServer(
    url: "http://127.0.0.1:4111",
    username: "opencode",
    password: "other-token"
  )
  static let info = ServerInfo(version: "0.0.0-fixture", pid: 1)
  static let projects = [
    ServerProject(id: "p1", name: "OpenCode", directory: "/work/opencode"),
    ServerProject(id: "p2", name: "Design", directory: "/work/design"),
  ]
}

final class CallCounter: Sendable {
  private let value = Mutex(0)

  func next() -> Int {
    value.withLock { count in
      count += 1
      return count
    }
  }

  var count: Int {
    value.withLock { $0 }
  }
}

/// A script whose last element repeats, so a test only lists the answers that differ.
final class Script<Value: Sendable>: Sendable {
  private let values: [Value]
  private let index = Mutex(0)

  init(_ values: [Value]) {
    precondition(!values.isEmpty)
    self.values = values
  }

  func next() -> Value {
    let current = index.withLock { index -> Int in
      defer { index += 1 }
      return index
    }
    return values[min(current, values.count - 1)]
  }
}

enum EventStep: Sendable {
  case phase(EventStreamPhase)
  case event(ServerEvent)
  case fail(OpenCodeClientError)
}

final class EventScript: Sendable {
  private let steps: [EventStep]

  init(_ steps: [EventStep]) {
    self.steps = steps
  }

  func stream(
    onPhase: @escaping @Sendable (EventStreamPhase) async -> Void
  ) -> AsyncThrowingStream<ServerEvent, any Error> {
    let steps = steps
    return AsyncThrowingStream { continuation in
      let task = Task {
        for step in steps {
          if Task.isCancelled { break }
          switch step {
          case .phase(let phase):
            await onPhase(phase)
          case .event(let event):
            continuation.yield(event)
          case .fail(let error):
            continuation.finish(throwing: error)
            return
          }
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}

/// A stream the test drives one step at a time, so connection phases cannot race an assertion.
final class ControlledEventScript: Sendable {
  private let continuation: AsyncStream<EventStep>.Continuation
  private let updates: AsyncStream<EventStep>

  init() {
    let pair = AsyncStream<EventStep>.makeStream()
    updates = pair.stream
    continuation = pair.continuation
  }

  func push(_ step: EventStep) {
    continuation.yield(step)
  }

  func finish() {
    continuation.finish()
  }

  func stream(
    onPhase: @escaping @Sendable (EventStreamPhase) async -> Void
  ) -> AsyncThrowingStream<ServerEvent, any Error> {
    let updates = updates
    return AsyncThrowingStream { continuation in
      let task = Task {
        for await step in updates {
          if Task.isCancelled { break }
          switch step {
          case .phase(let phase):
            await onPhase(phase)
          case .event(let event):
            continuation.yield(event)
          case .fail(let error):
            continuation.finish(throwing: error)
            return
          }
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}

enum EventSource: Sendable {
  case script(EventScript)
  case controlled(ControlledEventScript)

  func stream(
    onPhase: @escaping @Sendable (EventStreamPhase) async -> Void
  ) -> AsyncThrowingStream<ServerEvent, any Error> {
    switch self {
    case .script(let script): script.stream(onPhase: onPhase)
    case .controlled(let script): script.stream(onPhase: onPhase)
    }
  }
}

struct ScriptedClient: Sendable {
  var health: Script<Result<ServerInfo, OpenCodeClientError>>
  var projects: Script<Result<[ServerProject], OpenCodeClientError>>
  var redeem: Result<OpenCodeServer, OpenCodeClientError> = .success(TestServer.server)
  var events: EventSource = .script(EventScript([.phase(.connected)]))
  var healthCalls = CallCounter()
  var projectCalls = CallCounter()
  var redeemCalls = CallCounter()

  func client() -> OpenCodeClient {
    let healthCalls = healthCalls
    let projectCalls = projectCalls
    let redeemCalls = redeemCalls
    return OpenCodeClient(
      health: { _ in
        _ = healthCalls.next()
        return try health.next().get()
      },
      redeemPairing: { _ in
        _ = redeemCalls.next()
        return try redeem.get()
      },
      projects: { _ in
        _ = projectCalls.next()
        return try projects.next().get()
      },
      sessionPage: { _, _, _ in throw OpenCodeClientError(.unsupported) },
      getSession: { _, _ in throw OpenCodeClientError(.unsupported) },
      activeSessionIDs: { _ in throw OpenCodeClientError(.unsupported) },
      events: { _, onPhase in events.stream(onPhase: onPhase) }
    )
  }
}
