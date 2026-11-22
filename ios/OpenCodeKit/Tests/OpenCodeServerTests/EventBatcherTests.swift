import Foundation
import OpenCodeCore
import OpenCodeServer
import Testing

@Suite("Event batcher")
struct EventBatcherTests {
  private func collect(
    _ stream: AsyncThrowingStream<ServerEvent, any Error>,
    count: Int
  ) async throws -> [ServerEvent] {
    var events: [ServerEvent] = []
    for try await event in stream {
      events.append(event)
      if events.count == count { break }
    }
    return events
  }

  @Test("adjacent text deltas coalesce into one batch")
  func coalescesDeltas() async throws {
    let batcher = EventBatcher(clock: ClockClient.testValue)
    await batcher.receive(
      .contentBatch(
        sessionID: "s1",
        events: [.textDelta(messageID: "m", ordinal: 0, delta: "Hel", accumulatedText: nil)]
      )
    )
    await batcher.receive(
      .contentBatch(
        sessionID: "s1",
        events: [.textDelta(messageID: "m", ordinal: 0, delta: "lo", accumulatedText: nil)]
      )
    )
    await batcher.flush()

    let events = try await collect(await batcher.events, count: 1)
    #expect(
      events == [
        .contentBatch(
          sessionID: "s1",
          events: [.textDelta(messageID: "m", ordinal: 0, delta: "Hello", accumulatedText: nil)]
        )
      ]
    )
  }

  @Test("a non-content event arrives after the deltas it follows")
  func ordersBeforeNonContent() async throws {
    let batcher = EventBatcher(clock: ClockClient.testValue)
    await batcher.receive(
      .contentBatch(sessionID: "s1", events: [.textDelta(messageID: "m", ordinal: 0, delta: "a", accumulatedText: nil)])
    )
    await batcher.receive(.sessionRenamed(sessionID: "s1", title: "New"))

    let events = try await collect(await batcher.events, count: 2)
    #expect(events.count == 2)
    guard case .contentBatch = events[0] else {
      Issue.record("expected the batch first")
      return
    }
    #expect(events[1] == .sessionRenamed(sessionID: "s1", title: "New"))
  }

  @Test("a non-content event for another session flushes every pending batch first")
  func globalEventFlushesAll() async throws {
    let batcher = EventBatcher(clock: ClockClient.testValue)
    await batcher.receive(
      .contentBatch(sessionID: "s1", events: [.textDelta(messageID: "a", ordinal: 0, delta: "1", accumulatedText: nil)])
    )
    await batcher.receive(
      .contentBatch(sessionID: "s2", events: [.textDelta(messageID: "b", ordinal: 0, delta: "2", accumulatedText: nil)])
    )
    await batcher.receive(.projectUpdated(ServerProject(id: "p", name: "P", directory: "/p")))

    let events = try await collect(await batcher.events, count: 3)
    #expect(events.count == 3)
    if case .contentBatch(let sessionID, _) = events[0] { #expect(sessionID == "s1") }
    if case .contentBatch(let sessionID, _) = events[1] { #expect(sessionID == "s2") }
    if case .projectUpdated = events[2] {} else { Issue.record("expected the project update last") }
  }

  @Test("a batch flushes at 256 mutations without waiting for the timer")
  func batchLimit() async throws {
    let batcher = EventBatcher(clock: ClockClient.testValue)
    let delta = LiveContentEvent.textDelta(messageID: "m", ordinal: 0, delta: "x", accumulatedText: nil)
    // 256 events from one call: the batch limit is reached on receipt.
    await batcher.receive(.contentBatch(sessionID: "s1", events: Array(repeating: delta, count: 256)))

    // The whole run coalesces to a single delta, so the emitted batch is one event.
    let events = try await collect(await batcher.events, count: 1)
    guard case .contentBatch(_, let content) = events[0] else {
      Issue.record("expected a content batch")
      return
    }
    #expect(content.count == 1)
    #expect(content.first == .textDelta(messageID: "m", ordinal: 0, delta: String(repeating: "x", count: 256), accumulatedText: nil))
  }

  @Test("a consumer that falls behind ends the stream with an overflow")
  func overflowTerminates() async throws {
    let batcher = EventBatcher(configuration: .init(capacity: 2), clock: ClockClient.testValue)
    await batcher.receive(.connected)
    await batcher.receive(.modelsChanged)
    await batcher.receive(.agentsChanged)

    let stream = await batcher.events
    var received: [ServerEvent] = []
    do {
      for try await event in stream {
        received.append(event)
      }
      Issue.record("expected an overflow")
    } catch {
      #expect(error is EventStreamOverflow)
    }
    #expect(received == [.connected, .modelsChanged])
    #expect(await batcher.isTerminated)
  }

  @Test("the flush timer delivers a pending batch after the interval")
  func timerFlush() async throws {
    let clock = ClockClient.gate()
    let batcher = EventBatcher(clock: clock.client)
    await batcher.receive(
      .contentBatch(sessionID: "s1", events: [.textDelta(messageID: "m", ordinal: 0, delta: "a", accumulatedText: nil)])
    )
    while clock.pendingCount == 0 {
      await Task.yield()
    }
    clock.releaseNext()

    let events = try await collect(await batcher.events, count: 1)
    #expect(events.count == 1)
  }

  @Test("finishing flushes what is pending, then ends the stream")
  func finishFlushes() async throws {
    let batcher = EventBatcher(clock: ClockClient.testValue)
    await batcher.receive(
      .contentBatch(sessionID: "s1", events: [.textStarted(messageID: "m", ordinal: 0)])
    )
    await batcher.finish()

    let stream = await batcher.events
    var events: [ServerEvent] = []
    for try await event in stream {
      events.append(event)
    }
    #expect(events == [.contentBatch(sessionID: "s1", events: [.textStarted(messageID: "m", ordinal: 0)])])
  }

  @Test("failing ends the stream after the queued events")
  func failEnds() async throws {
    let batcher = EventBatcher(clock: ClockClient.testValue)
    await batcher.receive(.connected)
    await batcher.fail(OpenCodeClientError(.streamEnded))

    let stream = await batcher.events
    var caught: (any Error)?
    var events: [ServerEvent] = []
    do {
      for try await event in stream {
        events.append(event)
      }
    } catch {
      caught = error
    }
    #expect(events == [.connected])
    #expect((caught as? OpenCodeClientError)?.failure == .streamEnded)
  }
}
