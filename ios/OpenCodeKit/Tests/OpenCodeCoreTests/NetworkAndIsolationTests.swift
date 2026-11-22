import Foundation
import OpenCodeCore
import OpenCodeServer
import OpenCodeTestSupport
import Testing

@Suite("Test isolation")
struct TestIsolationTests {
  @Test("two environments share no storage, directory or identifier sequence")
  func environmentsAreDisjoint() throws {
    let first = IsolatedTestEnvironment(testName: "first")
    let second = IsolatedTestEnvironment(testName: "second")
    defer {
      first.cleanUp()
      second.cleanUp()
    }

    _ = first.storage.write(Data("first".utf8), for: "draft")

    #expect(first.storage.read("draft") == .value(Data("first".utf8)))
    #expect(second.storage.read("draft") == .missing)
    #expect(second.storage.allKeys.isEmpty)
    #expect(first.root != second.root)
    #expect(first.root.pathComponents.count < 12)
    #expect(!first.root.path.contains(NSHomeDirectory() + "/Documents"))
  }

  @Test("the deterministic identifier client counts up from one")
  func identifiersAreDeterministic() {
    let client = UuidClient.incrementing()
    let first = client.uuid()
    let second = client.uuid()

    #expect(first.uuidString == "00000000-0000-4000-8000-000000000001")
    #expect(second.uuidString == "00000000-0000-4000-8000-000000000002")
  }

  @Test("the test date client is pinned")
  func dateIsPinned() {
    #expect(DateClient.testValue.now() == Date(timeIntervalSince1970: 0))
  }
}

@Suite("Network guard", .serialized)
struct NetworkGuardTests {
  @Test("a host with no fixture is blocked and recorded")
  func publicHostIsBlocked() async throws {
    let session = NetworkGuard.makeSession()
    let url = try #require(URL(string: InertFixtures.publicURL))

    await #expect(throws: (any Error).self) {
      _ = try await session.data(from: url)
    }

    #expect(NetworkGuard.requestedHosts.contains("example.com"))
    #expect(NetworkGuard.fixture(for: "example.com") == nil)
  }

  @Test("a registered fixture is answered locally, never from the network")
  func fixtureIsServed() async throws {

    let body = Data(#"{"version":"0.0.0-fixture","pid":1}"#.utf8)
    NetworkGuard.register(
      host: InertFixtures.fixtureHost,
      fixture: .init(statusCode: 200, body: body)
    )

    let session = NetworkGuard.makeSession()
    let url = try #require(URL(string: InertFixtures.fixtureBaseURL + "/api/info"))
    let (data, response) = try await session.data(from: url)

    #expect(data == body)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
  }
}

@Suite("Server endpoint")
struct ServerEndpointTests {
  @Test("valid addresses are accepted with and without a trailing slash")
  func acceptsValidAddresses() {
    #expect(ServerEndpoint(address: "http://127.0.0.1:4110") != nil)
    #expect(ServerEndpoint(address: "https://host.example") != nil)
    #expect(ServerEndpoint(address: "https://host.example/") != nil)
    #expect(ServerEndpoint(address: "  https://host.example  ") != nil)
  }

  @Test("credentials, query, fragment, path and non-HTTP schemes are rejected")
  func rejectsInvalidAddresses() {
    #expect(ServerEndpoint(address: "https://user:pass@host.example") == nil)
    #expect(ServerEndpoint(address: "https://host.example/?token=1") == nil)
    #expect(ServerEndpoint(address: "https://host.example/#frag") == nil)
    #expect(ServerEndpoint(address: "https://host.example/sub") == nil)
    #expect(ServerEndpoint(address: "ftp://host.example") == nil)
    #expect(ServerEndpoint(address: "host.example") == nil)
    #expect(ServerEndpoint(address: "") == nil)
  }

  @Test("path replaces a saved path and the directory query uses the server's name")
  func buildsURLs() throws {
    let endpoint = try #require(ServerEndpoint(address: "https://host.example"))
    let directory = ServerEndpoint.locationDirectory("/work/project")

    #expect(directory.0 == "location[directory]")
    #expect(directory.1 == "/work/project")

    let url = try #require(
      endpoint.url(path: "api/session", query: [directory.0: directory.1, "limit": "50"])
    )
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let items = Dictionary(
      uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
    )

    #expect(url.path == "/api/session")
    #expect(items["location[directory]"] == "/work/project")
    #expect(items["limit"] == "50")
  }

  @Test("the display address never carries credentials")
  func displayAddressOmitsCredentials() throws {
    let endpoint = try #require(ServerEndpoint(address: "https://host.example"))
    #expect(endpoint.displayAddress == "https://host.example")
  }
}
