import Foundation
import Synchronization

/// A bounded, pull-based hand-off between a producer that cannot wait (a URLSession delegate or a
/// parser loop) and an async consumer.
///
/// `push` never blocks and never drops silently: when the buffer is full it reports `overflow`, and
/// the owner finishes the connection so the caller reconnects and rehydrates from REST. That is the
/// audited behaviour for both the event stream and transport chunks: a gap in delivery is a
/// failure, not something to hide.
public final class BoundedChannel<Element: Sendable>: @unchecked Sendable {
  // Mutex-guarded: `push` runs from a URLSession delegate callback and cannot await actor
  // isolation without reordering frames.
  public enum PushOutcome: Sendable, Equatable {
    /// Queued or handed to a waiting consumer, with this many free slots left.
    case accepted(remaining: Int)
    case overflow
    case closed
  }

  private struct State {
    var items: [Element] = []
    var waiter: CheckedContinuation<Element?, any Error>?
    var failure: (any Error)?
    var isClosed = false
    var isCancelled = false
    var closeHandler: (@Sendable () -> Void)?
  }

  private let capacity: Int
  private let state = Mutex(State())

  public init(capacity: Int) {
    self.capacity = max(1, capacity)
  }

  public var bufferedCount: Int {
    state.withLock { $0.items.count }
  }

  public var isClosed: Bool {
    state.withLock { $0.isClosed || $0.isCancelled }
  }

  @discardableResult
  public func push(_ element: Element) -> PushOutcome {
    let action: (waiter: CheckedContinuation<Element?, any Error>?, outcome: PushOutcome) = state.withLock { state in
      if state.isClosed || state.isCancelled {
        return (nil, .closed)
      }
      if let waiter = state.waiter {
        state.waiter = nil
        return (waiter, .accepted(remaining: capacity - state.items.count))
      }
      if state.items.count >= capacity {
        return (nil, .overflow)
      }
      state.items.append(element)
      return (nil, .accepted(remaining: capacity - state.items.count))
    }
    action.waiter?.resume(returning: element)
    return action.outcome
  }

  /// No more elements: the consumer receives the queued ones, then `nil`.
  public func finish() {
    let action = state.withLock { state -> (CheckedContinuation<Element?, any Error>?, (@Sendable () -> Void)?) in
      guard !state.isClosed, !state.isCancelled else { return (nil, nil) }
      state.isClosed = true
      let waiter = state.waiter
      state.waiter = nil
      let handler = state.closeHandler
      state.closeHandler = nil
      return (waiter, handler)
    }
    action.0?.resume(returning: nil)
    action.1?()
  }

  /// No more elements: the consumer receives the queued ones, then this error.
  public func fail(_ error: any Error) {
    let action = state.withLock { state -> (CheckedContinuation<Element?, any Error>?, (@Sendable () -> Void)?) in
      guard !state.isClosed, !state.isCancelled else { return (nil, nil) }
      state.failure = error
      state.isClosed = true
      let waiter = state.waiter
      state.waiter = nil
      let handler = state.closeHandler
      state.closeHandler = nil
      return (waiter, handler)
    }
    action.0?.resume(throwing: error)
    action.1?()
  }

  /// The consumer stopped: release the producer's waiter and refuse further pushes.
  public func cancel() {
    let action = state.withLock { state -> (CheckedContinuation<Element?, any Error>?, (@Sendable () -> Void)?) in
      guard !state.isClosed, !state.isCancelled else { return (nil, nil) }
      state.isCancelled = true
      state.items.removeAll()
      let waiter = state.waiter
      state.waiter = nil
      let handler = state.closeHandler
      state.closeHandler = nil
      return (waiter, handler)
    }
    action.0?.resume(throwing: CancellationError())
    action.1?()
  }

  /// Runs once when the channel closes for any reason, so the producer can cancel its socket.
  public func setCloseHandler(_ handler: @escaping @Sendable () -> Void) {
    let fireNow = state.withLock { state -> Bool in
      if state.isClosed || state.isCancelled { return true }
      state.closeHandler = handler
      return false
    }
    if fireNow { handler() }
  }

  /// A stream that pulls from this channel. No element is buffered by the stream itself, so the
  /// channel's capacity is the only bound.
  public var stream: AsyncThrowingStream<Element, any Error> {
    // The stream retains the channel so a producer that has finished cannot deallocate queued
    // elements out from under a consumer that is still draining them.
    AsyncThrowingStream(unfolding: { try await self.next() })
  }

  func next() async throws -> Element? {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let outcome: (element: Element?, error: (any Error)?, finish: Bool) = state.withLock { state in
          if !state.items.isEmpty {
            return (state.items.removeFirst(), nil, false)
          }
          if let failure = state.failure {
            return (nil, failure, false)
          }
          if state.isCancelled {
            return (nil, CancellationError(), false)
          }
          if state.isClosed {
            return (nil, nil, true)
          }
          state.waiter = continuation
          return (nil, nil, false)
        }
        if let element = outcome.element {
          continuation.resume(returning: element)
        } else if let error = outcome.error {
          continuation.resume(throwing: error)
        } else if outcome.finish {
          continuation.resume(returning: nil)
        }
      }
    } onCancel: {
      self.cancel()
    }
  }
}
