import Foundation
import OpenCodeCore
import OpenCodeServer
import Testing

/// Platform checks for the pieces that only exist on the app's Apple SDK build.
@Suite("Platform storage and endpoints")
struct PlatformStorageTests {
  @Test("user defaults storage reports write, read and delete outcomes")
  func userDefaultsOutcomes() throws {
    let suite = "opencode-migration-tests-\(UUID().uuidString)"
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

    let storage = UserDefaultsStorage(suiteName: suite)
    #expect(storage.read("key") == .missing)
    #expect(storage.write(Data("value".utf8), for: "key") == .success)
    #expect(storage.read("key") == .value(Data("value".utf8)))
    #expect(storage.delete("key") == .success)
    #expect(storage.read("key") == .missing)
  }

  @Test("in-memory storage keeps keys apart")
  func inMemoryStorage() {
    let storage = InMemoryStorage()
    #expect(storage.write(Data("a".utf8), for: "one") == .success)
    #expect(storage.write(Data("b".utf8), for: "two") == .success)

    #expect(storage.allKeys == ["one", "two"])
    #expect(storage.read("one") == .value(Data("a".utf8)))
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
