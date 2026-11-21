import Foundation
import OpenCodeCore
import OpenCodeServer
import Synchronization
import Testing

@Suite("Bounded channel")
struct BoundedChannelTests {
  @Test("a waiter hand-off does not lose the next element")
  func waiterHandoff() async throws {
    let channel = BoundedChannel<Int>(capacity: 4)
    let stream = channel.stream
    let consumer = Task {
      var received: [Int] = []
      for try await value in stream {
        received.append(value)
        if received.count == 2 { break }
      }
      return received
    }
    try await Task.sleep(for: .milliseconds(20))
    #expect(channel.push(1) == .accepted(remaining: 4))
    #expect(channel.push(2) == .accepted(remaining: 3))

    #expect(try await consumer.value == [1, 2])
  }

  @Test("queued elements are delivered before a failure")
  func queuedBeforeFailure() async throws {
    let channel = BoundedChannel<Int>(capacity: 4)
    channel.push(1)
    channel.push(2)
    channel.fail(OpenCodeClientError(.streamEnded))

    var received: [Int] = []
    var caught: (any Error)?
    do {
      for try await value in channel.stream {
        received.append(value)
      }
    } catch {
      caught = error
    }
    #expect(received == [1, 2])
    #expect((caught as? OpenCodeClientError)?.failure == .streamEnded)
  }

  @Test("a full channel reports overflow instead of dropping")
  func overflow() {
    let channel = BoundedChannel<Int>(capacity: 2)
    #expect(channel.push(1) == .accepted(remaining: 1))
    #expect(channel.push(2) == .accepted(remaining: 0))
    #expect(channel.push(3) == .overflow)
    #expect(channel.bufferedCount == 2)
  }

  @Test("cancelling the consumer refuses further pushes")
  func cancellation() {
    let channel = BoundedChannel<Int>(capacity: 2)
    channel.cancel()
    #expect(channel.push(1) == .closed)
  }

  @Test("a close handler runs once when the channel closes")
  func closeHandler() {
    let channel = BoundedChannel<Int>(capacity: 2)
    let fired = Counter()
    channel.setCloseHandler { fired.increment() }
    channel.finish()
    channel.finish()
    #expect(fired.value == 1)
  }
}

final class Counter: Sendable {
  private let state = Mutex(0)

  var value: Int { state.withLock { $0 } }

  func increment() { state.withLock { $0 += 1 } }
}
