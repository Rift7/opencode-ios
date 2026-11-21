import Foundation
import OpenCodeCore
import OpenCodeServer
import Testing

/// Platform checks for the pieces that only exist on the app's Apple SDK build.
@Suite("Platform storage and endpoints")
struct PlatformStorageTests {
  @Test("user defaults storage round-trips bytes")
  func userDefaultsRoundTrip() throws {
    let suite = "opencode-migration-tests-\(UUID().uuidString)"
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

    let storage = UserDefaultsStorage(suiteName: suite)
    storage.setData(Data("value".utf8), forKey: "key")
    #expect(storage.data(forKey: "key") == Data("value".utf8))

    storage.removeValue(forKey: "key")
    #expect(storage.data(forKey: "key") == nil)
  }

  @Test("in-memory storage keeps keys apart")
  func inMemoryStorage() {
    let storage = InMemoryStorage()
    storage.setData(Data("a".utf8), forKey: "one")
    storage.setData(Data("b".utf8), forKey: "two")

    #expect(storage.allKeys == ["one", "two"])
    #expect(storage.data(forKey: "one") == Data("a".utf8))
  }

  @Test("the endpoint rejects credentials and keeps the directory query name")
  func endpointBehaviour() throws {
    #expect(ServerEndpoint(address: "https://user:pass@host.example") == nil)

    let endpoint = try #require(ServerEndpoint(address: "http://127.0.0.1:4110"))
    let directory = ServerEndpoint.locationDirectory("/work")
    let url = try #require(endpoint.url(path: "/api/info", query: [directory.0: directory.1]))
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let items = Dictionary(
      uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
    )

    #expect(url.path == "/api/info")
    #expect(items["location[directory]"] == "/work")
  }
}
