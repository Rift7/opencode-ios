import Foundation
import OpenCodeCore

/// Keeps high-frequency events out of reducers: adjacent deltas for one part coalesce and flush 75 ms
/// after the first, at most 256 mutations per batch. A non-content event first flushes the deltas it
/// must follow, so ordering is never lost.
///
/// The buffer handed downstream is bounded (128 by default). If the consumer falls that far behind,
/// the connection ends with `EventStreamOverflow` instead of dropping an event: a silent gap would
/// make the projected transcript wrong, so the owner reconnects and rehydrates from REST.
public actor EventBatcher {
  public struct Configuration: Sendable, Equatable {
    public var flushInterval: Duration
    public var capacity: Int
    public var batchLimit: Int

    public init(
      flushInterval: Duration = .milliseconds(75),
      capacity: Int = 128,
      batchLimit: Int = 256
    ) {
      self.flushInterval = flushInterval
      self.capacity = capacity
      self.batchLimit = batchLimit
    }

    public static let standard = Configuration()
  }

  private let configuration: Configuration
  private let clock: ClockClient
  private let channel: BoundedChannel<ServerEvent>
  private var pending: [String: [LiveContentEvent]] = [:]
  private var pendingSessions: [String] = []
  private var pendingCount = 0
  private var flushTask: Task<Void, Never>?
  private var terminated = false

  public init(configuration: Configuration = .standard, clock: ClockClient) {
    self.configuration = configuration
    self.clock = clock
    self.channel = BoundedChannel(capacity: configuration.capacity)
  }

  /// The bounded event stream this batcher feeds.
  public var events: AsyncThrowingStream<ServerEvent, any Error> {
    channel.stream
  }

  /// Runs once when the consumer stops, so the connection's read and watchdog tasks end with it.
  public func setCloseHandler(_ handler: @escaping @Sendable () -> Void) {
    channel.setCloseHandler(handler)
  }

  public var bufferedCount: Int {
    channel.bufferedCount
  }

  public var isTerminated: Bool {
    terminated
  }

  public func receive(_ event: ServerEvent) {
    guard !terminated else { return }
    if case .contentBatch(let sessionID, let events) = event {
      append(events, sessionID: sessionID)
      if pendingCount >= configuration.batchLimit {
        flushAll()
      } else {
        scheduleFlush()
      }
      return
    }
    if let target = event.targetSessionID {
      flush(sessionID: target)
    } else {
      flushAll()
    }
    emit(event)
  }

  /// Delivers every pending batch now.
  public func flush() {
    flushTask?.cancel()
    flushTask = nil
    flushAll()
  }

  /// Ends the stream after the queued events, without an error (the owner decides what a clean end
  /// means; this client reports an ended connection as an error).
  public func finish() {
    guard !terminated else { return }
    flush()
    terminated = true
    channel.finish()
  }

  /// The connection is being torn down: stop flushing and end the consumer's stream now.
  public func cancel() {
    guard !terminated else { return }
    flushTask?.cancel()
    flushTask = nil
    pending.removeAll()
    pendingSessions.removeAll()
    pendingCount = 0
    terminated = true
    channel.cancel()
  }

  /// Ends the stream after the queued events with `error`.
  public func fail(_ error: any Error) {
    guard !terminated else { return }
    flushTask?.cancel()
    flushTask = nil
    pending.removeAll()
    pendingSessions.removeAll()
    pendingCount = 0
    terminated = true
    channel.fail(error)
  }

  private func append(_ events: [LiveContentEvent], sessionID: String) {
    if pending[sessionID] == nil {
      pending[sessionID] = []
      pendingSessions.append(sessionID)
    }
    pending[sessionID]?.appendCoalescingDeltas(events)
    pendingCount += events.count
  }

  private func scheduleFlush() {
    guard flushTask == nil else { return }
    let interval = configuration.flushInterval
    let clock = clock
    flushTask = Task { [weak self] in
      try? await clock.sleep(interval)
      guard !Task.isCancelled else { return }
      await self?.flushDue()
    }
  }

  private func flushDue() {
    flushTask = nil
    flushAll()
  }

  private func flush(sessionID: String) {
    guard let events = pending.removeValue(forKey: sessionID) else { return }
    pendingSessions.removeAll { $0 == sessionID }
    pendingCount -= events.count
    if pending.isEmpty {
      flushTask?.cancel()
      flushTask = nil
    }
    guard !events.isEmpty else { return }
    emit(.contentBatch(sessionID: sessionID, events: events))
  }

  private func flushAll() {
    flushTask?.cancel()
    flushTask = nil
    guard !pending.isEmpty else { return }
    let batches = pendingSessions.compactMap { sessionID -> (String, [LiveContentEvent])? in
      guard let events = pending[sessionID] else { return nil }
      return (sessionID, events)
    }
    pending.removeAll()
    pendingSessions.removeAll()
    pendingCount = 0
    for (sessionID, events) in batches {
      guard !events.isEmpty else { continue }
      emit(.contentBatch(sessionID: sessionID, events: events))
    }
  }

  private func emit(_ event: ServerEvent) {
    guard !terminated else { return }
    switch channel.push(event) {
    case .accepted:
      return
    case .closed:
      terminated = true
    case .overflow:
      terminated = true
      channel.fail(EventStreamOverflow())
    }
  }
}
