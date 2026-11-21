import Foundation
import OpenCodeCore
import OpenCodeServer
import Testing

/// Read-only checks against a real server, opt-in through environment variables so the offline suite
/// never reaches the network:
///
/// ```
/// OPENCODE_LIVE_SERVER=http://127.0.0.1:4098 \
/// OPENCODE_LIVE_PASSWORD=… swift test --filter LiveServerTests
/// ```
///
/// The password is read from the environment and is never printed, logged or stored. Everything here
/// is a read; nothing mutates the server.
///
/// Scope note: the `opencode serve` snapshot available for this phase (0.0.0-dev-202611170722)
/// implements `/api/session`, `/api/session/active` and `/api/event`, but answers `/api/info` and
/// `/api/project` with its web shell. Those two routes are therefore not exercised here; the audited
/// contract remains the authority for them, and `STATUS.md` records the mismatch.
@Suite(
  "Live server",
  .serialized,
  .enabled(if: ProcessInfo.processInfo.environment["OPENCODE_LIVE_SERVER"] != nil)
)
struct LiveServerTests {
  private var server: OpenCodeServer? {
    let environment = ProcessInfo.processInfo.environment
    guard let address = environment["OPENCODE_LIVE_SERVER"] else { return nil }
    return OpenCodeServer(
      url: address,
      username: environment["OPENCODE_LIVE_USERNAME"] ?? "opencode",
      password: environment["OPENCODE_LIVE_PASSWORD"] ?? ""
    )
  }

  private var transport: HTTPTransport {
    let live = URLSessionTransport()
    return HTTPTransport(send: live.send, open: live.open)
  }

  private func client() -> OpenCodeClient {
    OpenCodeClient.live(transport: transport, clock: .liveValue, policy: .request)
  }

  @Test("session reads and the event stream work against a real server")
  func readOnlySmoke() async throws {
    let server = try #require(server)
    let client = client()

    let page = try await client.sessionPage(server, .search(""), 10)
    #expect(page.sessions.allSatisfy { !$0.id.isEmpty })

    _ = try await client.activeSessionIDs(server)

    let stream = EventStream(
      transport: transport,
      clock: .liveValue,
      connectDeadline: .seconds(5),
      idleDeadline: .seconds(30)
    )
    let connection = try await stream.connect(server: server)
    var sawConnected = false
    for try await event in connection.events {
      if case .connected = event {
        sawConnected = true
        break
      }
    }
    connection.close()
    #expect(sawConnected)
  }
}
