import Foundation
import OpenCodeCore
import OpenCodeServer
import Synchronization
import Testing

@Suite("Server link")
struct ServerLinkTests {
  private let preferred = "http://10.0.0.2:4096"
  private let alternate = "http://studio.ts.net:4096"

  private func server() -> OpenCodeServer {
    OpenCodeServer(
      url: preferred,
      username: "opencode",
      password: "token",
      alternateURLs: [alternate],
      preferredURLs: [preferred]
    )
  }

  @Test("the first address that answers as this server wins the race")
  func firstAnswerWins() async throws {
    let probed = Mutex<[String]>([])
    let probe = try await ServerLink.probe(
      server(),
      health: { candidate in
        probed.withLock { $0.append(candidate.url) }
        if candidate.url == self.alternate { throw OpenCodeClientError(.unreachable) }
        return ServerInfo(version: "0.0.0-fixture", pid: 7)
      },
      clock: .testValue,
      preferredHeadStart: .zero
    )

    #expect(probe.server.url == preferred)
    #expect(probe.info.pid == 7)
    #expect(probe.candidates == 2)
    #expect(probed.withLock { $0 }.contains(alternate))
  }

  @Test("a rejected sign-in is preferred over an unreachable address")
  func rejectedCredentialsBeatUnreachable() async {
    do {
      _ = try await ServerLink.probe(
        server(),
        health: { candidate in
          if candidate.url == self.preferred { throw OpenCodeClientError(.status(401)) }
          throw OpenCodeClientError(.unreachable)
        },
        clock: .testValue,
        preferredHeadStart: .zero
      )
      Issue.record("expected the race to fail")
    } catch let error as OpenCodeClientError {
      #expect(error.statusCode == 401)
    } catch {
      Issue.record("unexpected error: \(error)")
    }
  }

  @Test("backup addresses wait for the head start")
  func backupAddressWaits() async {
    let clock = ClockClient.recording()
    do {
      _ = try await ServerLink.probe(
        server(),
        health: { _ in throw OpenCodeClientError(.unreachable) },
        clock: clock.client,
        preferredHeadStart: .milliseconds(1500)
      )
      Issue.record("expected the race to fail")
    } catch {
      // Expected: no address answered.
    }
    #expect(clock.sleeps == [.milliseconds(1500)])
  }

  @Test("the preferred address is the first attempt when the list has one")
  func preferredAddressOnly() {
    let single = OpenCodeServer(url: preferred, password: "token")
    #expect(single.firstAttemptURLs == [preferred])
  }

  @Test("an address list keeps the pairing order for the first attempt")
  func preferredOrder() {
    let pair = OpenCodeServer(
      url: alternate,
      alternateURLs: [preferred],
      preferredURLs: [preferred, alternate]
    )
    #expect(pair.firstAttemptURLs == [preferred, alternate])
  }
}
