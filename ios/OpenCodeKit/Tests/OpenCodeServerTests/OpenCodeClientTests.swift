import Foundation
import OpenCodeCore
import OpenCodeServer
import Testing

@Suite("OpenCode client")
struct OpenCodeClientTests {
  private func client(
    _ handler: @escaping @Sendable (HTTPRequest, Int) async throws -> (status: Int, body: Data),
    clock: ClockClient = ClockClient.testValue,
    policy: RetryPolicy = .once
  ) -> (OpenCodeClient, RequestLog) {
    let log = RequestLog()
    return (
      OpenCodeClient.live(transport: Fixtures.transport(log: log, handler: handler), clock: clock, policy: policy),
      log
    )
  }

  private let server = OpenCodeServer(url: "http://10.0.0.2:4096", username: "opencode", password: "token")

  @Test("projects decode into display names and repository slugs")
  func projects() async throws {
    let (client, log) = client { _, _ in
      Fixtures.json(
        #"[{"id":"p1","canonical":"/Users/me/box","name":"Box","repository":"github.com/acme/box"},{"id":"p2","canonical":"/Users/me/plain"}]"#
      )
    }
    let projects = try await client.projects(server)

    #expect(projects.count == 2)
    #expect(projects[0].name == "Box")
    #expect(projects[0].repository == "box")
    #expect(projects[1].name == "plain")
    #expect(log.requests.first?.method == "GET")
    #expect(log.requests.first?.url.path == "/api/project")
    #expect(log.requests.first?.authorization == "Basic b3BlbmNvZGU6dG9rZW4=")
  }

  @Test("a session page sends the audited query and drops archived or child sessions")
  func sessionPage() async throws {
    let (client, log) = client { _, _ in
      Fixtures.json(
        #"{"data":[\#(Fixtures.session(id: "s1", title: "Root")),\#(Fixtures.session(id: "s2", parentID: "s1")),\#(Fixtures.session(id: "s3", title: "Old", archived: 1750000000000))],"cursor":{"next":"CURSOR"}}"#
      )
    }
    let page = try await client.sessionPage(server, .search("box"), 50)

    #expect(page.sessions.map(\.id) == ["s1"])
    #expect(page.next == "CURSOR")

    let url = try #require(log.requests.first?.url)
    let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(query.map { $0.name } == ["limit", "parentID", "archived", "order", "search"])
    #expect(query.map { $0.value ?? "" } == ["50", "null", "false", "desc", "box"])
    #expect(url.absoluteString.contains("location") == false)
  }

  @Test("a cursor page sends only the cursor and limit")
  func cursorPage() async throws {
    let (client, log) = client { _, _ in Fixtures.json(#"{"data":[],"cursor":{"next":"MORE"}}"#) }
    let page = try await client.sessionPage(server, .after("CURSOR"), 20)

    #expect(page.sessions.isEmpty)
    #expect(page.next == nil)
    let requestURL = try #require(log.requests.first?.url)
    let query = try #require(
      URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?.queryItems
    )
    #expect(query.map { $0.name } == ["limit", "cursor"])
    #expect(query.map { $0.value ?? "" } == ["20", "CURSOR"])
  }

  @Test("time.updated is milliseconds and the title falls back to the placeholder")
  func sessionDecoding() async throws {
    let (client, _) = client { _, _ in
      Fixtures.json(#"{"data":\#(Fixtures.session(id: "s1"))}"#)
    }
    let session = try await client.getSession(server, "s1")

    #expect(session.updatedAt == Date(timeIntervalSince1970: 1_750_000_000))
    #expect(session.title == "Untitled session")
    #expect(session.directory == "/work/box")
    #expect(!session.isArchived)
  }

  @Test("metadata.notification.always is read, and any other shape reads as off")
  func alwaysNotify() async throws {
    let (client, _) = client { request, _ in
      if request.url.path.hasSuffix("/on") {
        return Fixtures.json(
          #"{"data":{"id":"on","projectID":"p","time":{"updated":1},"location":{"directory":"/w"},"metadata":{"notification":{"always":true,"callbackURL":"https://x"}}}}"#
        )
      }
      return Fixtures.json(
        #"{"data":{"id":"off","projectID":"p","time":{"updated":1},"location":{"directory":"/w"},"metadata":{"notification":"nonsense"}}}"#
      )
    }
    let on = try await client.getSession(server, "on")
    let off = try await client.getSession(server, "off")
    #expect(on.alwaysNotify)
    #expect(!off.alwaysNotify)
  }

  @Test("active session IDs decode from the map envelope")
  func activeSessions() async throws {
    let (client, _) = client { _, _ in
      Fixtures.json(#"{"data":{"s1":{"type":"running"},"s2":{"type":"waiting"}}}"#)
    }
    #expect(try await client.activeSessionIDs(server) == ["s1", "s2"])
  }

  @Test("a 401 keeps its status and reads as rejected credentials")
  func unauthorized() async throws {
    let (client, _) = client { _, _ in Fixtures.json(#"{"error":"nope"}"#, status: 401) }
    do {
      _ = try await client.projects(server)
      Issue.record("expected a failure")
    } catch let error as OpenCodeClientError {
      #expect(error.statusCode == 401)
      #expect(error.copy == "The server rejected these credentials.")
      #expect(error.logSummary == "HTTP 401")
    }
  }

  @Test("a 404 body tagged LocationNotFoundError reads as the folder being gone")
  func locationMissing() async throws {
    let (client, _) = client { _, _ in
      Fixtures.json(#"{"_tag":"LocationNotFoundError","message":"gone"}"#, status: 404)
    }
    do {
      _ = try await client.getSession(server, "s1")
      Issue.record("expected a failure")
    } catch let error as OpenCodeClientError {
      #expect(error.isLocationMissing)
      #expect(error.copy == "The folder is gone")
    }
  }

  @Test("a body that does not match the contract is an undecodable error")
  func undecodable() async throws {
    let (client, _) = client { _, _ in Fixtures.json(#"{"data":{"id":42}}"#) }
    do {
      _ = try await client.getSession(server, "s1")
      Issue.record("expected a failure")
    } catch let error as OpenCodeClientError {
      #expect(error.failure == .undecodable(feature: "session"))
      #expect(error.copy == "The session does not match the current OpenCode V2 contract.")
    }
  }

  @Test("health needs no address list when a password proves the server")
  func healthWithPassword() async throws {
    let (client, log) = client { _, _ in
      Fixtures.json(#"{"version":"2.1.0","pid":42}"#)
    }
    let info = try await client.health(server)
    #expect(info.version == "2.1.0")
    #expect(log.requests.first?.url.path == "/api/info")
    #expect(log.requests.first?.timeout == 3.5)
    #expect(log.requests.first?.redirectPolicy == .reject)
  }

  @Test("a passwordless local server must list one of our other addresses")
  func healthIdentification() async throws {
    let local = OpenCodeServer(
      url: "http://10.0.0.2:4096",
      username: "opencode",
      password: "",
      alternateURLs: ["http://100.64.0.2:4096"]
    )
    let stranger = client { _, _ in Fixtures.json(#"{"version":"2.1.0","pid":1}"#) }.0
    do {
      _ = try await stranger.health(local)
      Issue.record("expected identification to fail")
    } catch let error as OpenCodeClientError {
      #expect(error.failure == .undecodable(feature: "server info"))
    }

    let friend = client { _, _ in
      Fixtures.json(#"{"version":"2.1.0","pid":1,"urls":["http://100.64.0.2:4096"]}"#)
    }.0
    _ = try await friend.health(local)
  }

  @Test("a transient status is retried under the request policy")
  func retriesTransientStatus() async throws {
    let log = RequestLog()
    let client = OpenCodeClient.live(
      transport: Fixtures.transport(log: log) { _, index in
        index < 3 ? Fixtures.json("{}", status: 503) : Fixtures.json("[]")
      },
      clock: ClockClient.recording().client,
      policy: .request
    )
    let projects = try await client.projects(server)
    #expect(projects.isEmpty)
    #expect(log.requests.count == 3)
  }

  @Test("pairing redeems once per candidate, unauthenticated and without redirects")
  func pairingRedemption() async throws {
    let log = RequestLog()
    let client = OpenCodeClient.live(
      transport: Fixtures.transport(log: log) { request, _ in
        if request.url.path.hasPrefix("/auth/connect/") {
          if request.url.host() == "100.64.0.2" {
            return Fixtures.json("{}", status: 404)
          }
          return Fixtures.json(
            #"{"token":"1750000000.abcdefghijklmnopqrstuvwxyz","device":{"name":"Anomaly Box"}}"#
          )
        }
        return Fixtures.json(#"{"version":"2.1.0","pid":1,"urls":["http://100.64.0.2:4096"]}"#)
      },
      clock: ClockClient.testValue
    )
    let link = try #require(
      PairingLink.decode(
        #"{"code":"\#(Fixtures.code)","urls":["http://127.0.0.1:4096","http://10.0.0.2:4096","http://100.64.0.2:4096"]}"#
      )
    )
    let paired = try await client.redeemPairing(link)

    #expect(paired.password == "1750000000.abcdefghijklmnopqrstuvwxyz")
    #expect(paired.name == "Anomaly Box")
    #expect(paired.url == "http://10.0.0.2:4096")
    #expect(paired.alternateURLs.contains("http://100.64.0.2:4096"))
    #expect(paired.alternateURLs.contains { $0.contains("127.0.0.1") } == false)
    #expect(paired.preferredURLs == ["http://10.0.0.2:4096", "http://100.64.0.2:4096"])

    let connect = try #require(log.requests.first { $0.url.path.hasPrefix("/auth/connect/") })
    #expect(connect.method == "GET")
    #expect(connect.authorization == nil)
    #expect(connect.redirectPolicy == .reject)
    #expect(connect.timeout == 15)
    #expect(log.requests.filter { $0.url.path.hasPrefix("/auth/connect/") }.count == 2)
  }

  @Test("a spent code reads as expired, and an old server as unsupported")
  func pairingFailures() async throws {
    let expired = client { _, _ in Fixtures.json(#"{"error":"used"}"#, status: 401) }.0
    let link = try #require(PairingLink.decode(#"{"code":"\#(Fixtures.code)","urls":["https://box.example"]}"#))
    do {
      _ = try await expired.redeemPairing(link)
      Issue.record("expected a pairing failure")
    } catch let error as OpenCodeClientError {
      #expect(error.failure == .pairingExpired)
      #expect(error.copy == ServerCopy.pairingExpired)
      #expect(error.copy.contains("opencode pair --remote"))
    }

    let unsupported = client { _, _ in Fixtures.json("{}", status: 404) }.0
    do {
      _ = try await unsupported.redeemPairing(link)
      Issue.record("expected a pairing failure")
    } catch let error as OpenCodeClientError {
      #expect(error.failure == .pairingUnsupported)
      #expect(error.copy == ServerCopy.pairingUnsupported)
    }
  }

  @Test("a cancelled read is not retried and surfaces as cancellation")
  func cancellation() async throws {
    let log = RequestLog()
    let transport = HTTPTransport(
      send: { request in
        log.append(request)
        try await Task.sleep(for: .seconds(60))
        return HTTPResponse(status: 200, headers: [:], body: Data("[]".utf8), finalURL: request.url)
      },
      open: { _ in throw TransportError.blocked }
    )
    let client = OpenCodeClient.live(
      transport: transport,
      clock: ClockClient.testValue,
      policy: .request
    )
    let task = Task { try await client.projects(server) }
    while log.requests.isEmpty { await Task.yield() }
    task.cancel()

    await #expect(throws: CancellationError.self) {
      _ = try await task.value
    }
    #expect(log.requests.count == 1)
  }

  @Test("a transport failure becomes a classified client error, never a raw URLError")
  func transportFailureClassification() async throws {
    let transport = HTTPTransport(
      send: { _ in throw URLError(.cannotConnectToHost) },
      open: { _ in throw TransportError.blocked }
    )
    let client = OpenCodeClient.live(transport: transport, clock: ClockClient.testValue, policy: .once)
    do {
      _ = try await client.projects(server)
      Issue.record("expected a failure")
    } catch let error as OpenCodeClientError {
      #expect(error.transport == .notSent)
      #expect(error.copy == "Couldn’t reach the OpenCode server")
      #expect(error.logSummary == "transport notSent")
    }
  }
}
