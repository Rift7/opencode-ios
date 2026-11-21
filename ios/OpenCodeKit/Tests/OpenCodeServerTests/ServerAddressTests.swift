import Foundation
import OpenCodeCore
import OpenCodeServer
import Testing

@Suite("Server origin")
struct ServerOriginTests {
  @Test("valid addresses are accepted with and without a trailing slash")
  func acceptsValidAddresses() throws {
    #expect(try #require(ServerOrigin(address: "http://127.0.0.1:4110")).address == "http://127.0.0.1:4110")
    #expect(try #require(ServerOrigin(address: "https://host.example/")).address == "https://host.example")
    #expect(try #require(ServerOrigin(address: "  https://host.example  ")).address == "https://host.example")
    #expect(try #require(ServerOrigin(address: "http://[::1]:8080")).address == "http://[::1]:8080")
  }

  @Test("credentials, query, fragment, path and non-HTTP schemes are rejected with a reason")
  func rejectsInvalidAddresses() {
    func problem(_ address: String) -> ServerOrigin.Problem? {
      if case .failure(let problem) = ServerOrigin.parse(address) { return problem }
      return nil
    }
    #expect(problem("https://user:pass@host.example") == .credentials)
    #expect(problem("https://host.example/?token=1") == .query)
    #expect(problem("https://host.example/#frag") == .query)
    #expect(problem("https://host.example/sub") == .path)
    #expect(problem("ftp://host.example") == .badScheme)
    #expect(problem("host.example") == .notAWebAddress)
    #expect(problem("") == .notAWebAddress)
  }

  @Test("two spellings of one address share a dedup key")
  func dedupKeyFillsTheDefaultPort() throws {
    let plain = try #require(ServerOrigin(address: "https://host.example"))
    let explicit = try #require(ServerOrigin(address: "https://HOST.example:443"))

    #expect(plain.dedupKey == "https://host.example:443")
    #expect(plain.dedupKey == explicit.dedupKey)
  }

  @Test("deduplication keeps the first spelling of an address")
  func deduplicationKeepsFirstSpelling() {
    let result = ServerOrigin.deduplicated([
      "https://host.example:443", "https://host.example", "http://host.example:80/",
      "http://host.example:80", "not an address",
    ])
    #expect(result == ["https://host.example:443", "http://host.example:80"])
  }

  @Test("loopback, private, overlay and public addresses classify by their literal")
  func classifiesRoutes() throws {
    func route(_ address: String) throws -> ConnectionRoute {
      try #require(ServerOrigin(address: address)).route
    }
    #expect(try route("http://127.0.0.1:4096") == .loopback)
    #expect(try route("http://localhost:4096") == .loopback)
    #expect(try route("http://[::1]:4096") == .loopback)
    #expect(try route("http://10.1.2.3:4096") == .localNetwork)
    #expect(try route("http://172.16.0.1:4096") == .localNetwork)
    #expect(try route("http://172.32.0.1:4096") == .internet)
    #expect(try route("http://192.168.1.5:4096") == .localNetwork)
    #expect(try route("http://169.254.1.1:4096") == .localNetwork)
    #expect(try route("http://100.64.0.3:4096") == .tailscale)
    #expect(try route("http://[fd7a:115c:a1e0::1]:4096") == .tailscale)
    #expect(try route("http://[fd00::1]:4096") == .localNetwork)
    #expect(try route("http://[fe80::1%en0]:4096") == .localNetwork)
    #expect(try route("https://basebook.tail1234.ts.net:4443") == .tailscale)
    #expect(try route("http://basebook.local:4096") == .localNetwork)
    #expect(try route("https://opencode.ai") == .internet)
    #expect(try route("https://fd.example.com") == .internet)
  }

  @Test("plain HTTP is allowed only to local and overlay addresses")
  func cleartextPolicy() {
    #expect(TransportSecurity.allowsInsecureHTTP(host: "127.0.0.1"))
    #expect(TransportSecurity.allowsInsecureHTTP(host: "10.0.0.4"))
    #expect(TransportSecurity.allowsInsecureHTTP(host: "192.168.0.9"))
    #expect(TransportSecurity.allowsInsecureHTTP(host: "100.100.1.2"))
    #expect(TransportSecurity.allowsInsecureHTTP(host: "169.254.3.4"))
    #expect(TransportSecurity.allowsInsecureHTTP(host: "basebook.local"))
    #expect(TransportSecurity.allowsInsecureHTTP(host: "basebook"))
    #expect(TransportSecurity.allowsInsecureHTTP(host: "box.tail1234.ts.net"))
    #expect(TransportSecurity.allowsInsecureHTTP(host: "box.netbird.cloud"))
    #expect(TransportSecurity.allowsInsecureHTTP(host: "box.home.arpa"))
    #expect(!TransportSecurity.allowsInsecureHTTP(host: "opencode.ai"))
    #expect(!TransportSecurity.allowsInsecureHTTP(host: "8.8.8.8"))
    #expect(!TransportSecurity.allowsInsecureHTTP(host: "example.com"))
  }

  @Test("https is never refused by the cleartext policy")
  func httpsIsAlwaysAllowed() throws {
    let url = try #require(URL(string: "https://example.com/api/info"))
    #expect(TransportSecurity.allowsInsecureHTTP(url: url))
  }
}

@Suite("Server address")
struct OpenCodeServerAddressTests {
  @Test("the directory query travels escaped and decodes to the server's name")
  func encodesLocationQuery() throws {
    let server = OpenCodeServer(url: "http://192.168.1.5:4096", password: "secret")
    let url = try #require(
      server.endpoint(
        path: "/api/session",
        query: [("location[directory]", "/Users/me/Project One"), ("limit", "50")]
      )
    )
    let raw = url.absoluteString
    #expect(raw == "http://192.168.1.5:4096/api/session?location%5Bdirectory%5D=/Users/me/Project%20One&limit=50")

    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let items = Dictionary(
      uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
    )
    #expect(items["location[directory]"] == "/Users/me/Project One")
    #expect(items["limit"] == "50")
  }

  @Test("a saved path or query never survives into a request")
  func endpointReplacesAnySavedPath() throws {
    let server = OpenCodeServer(url: "https://host.example/base?x=1")
    let url = try #require(server.endpoint(path: "/api/info"))
    #expect(url.absoluteString == "https://host.example/api/info")
  }

  @Test("credentials are a Basic header, and only when a password is set")
  func authorization() {
    #expect(OpenCodeServer(url: "http://host:1").basicAuthorization == nil)
    let server = OpenCodeServer(url: "http://host:1", username: "opencode", password: "token")
    #expect(server.basicAuthorization == "Basic b3BlbmNvZGU6dG9rZW4=")
    #expect(server.wireHeaders["Authorization"] == "Basic b3BlbmNvZGU6dG9rZW4=")
  }

  @Test("a header that cannot be sent is skipped, not fatal")
  func invalidHeadersAreSkipped() {
    let server = OpenCodeServer(
      url: "https://host.example",
      username: "opencode",
      password: "token",
      headers: [
        .init(name: "CF-Access-Client-Id", value: "id"),
        .init(name: "Bad Name", value: "x"),
        .init(name: "X-Injected", value: "a\r\nHost: evil"),
      ]
    )
    let headers = server.wireHeaders
    #expect(headers["CF-Access-Client-Id"] == "id")
    #expect(headers["Bad Name"] == nil)
    #expect(headers["X-Injected"] == nil)
    #expect(headers["Authorization"] != nil)
  }

  @Test("the request carries the server's headers for its own origin")
  func requestCarriesHeaders() throws {
    let server = OpenCodeServer(
      url: "https://host.example",
      password: "token",
      headers: [.init(name: "CF-Access-Client-Id", value: "id")]
    )
    let request = try #require(
      server.request(path: "/api/project", method: "GET", timeout: 7, redirectPolicy: .reject)
    )
    #expect(request.headers["CF-Access-Client-Id"] == "id")
    #expect(request.authorization == "Basic b3BlbmNvZGU6dG9rZW4=")
    #expect(request.wireHeaders["Authorization"] == "Basic b3BlbmNvZGU6dG9rZW4=")
    #expect(request.timeout == 7)
    #expect(request.redirectPolicy == .reject)
  }

  @Test("a server keeps one identity across an address change")
  func persistenceIDIgnoresOrder() {
    let first = OpenCodeServer(
      url: "http://10.0.0.2:4096",
      username: "opencode",
      password: "",
      alternateURLs: ["http://100.64.0.2:4096"]
    )
    let reordered = OpenCodeServer(
      url: "http://100.64.0.2:4096",
      username: "opencode",
      password: "",
      alternateURLs: ["http://10.0.0.2:4096"]
    )
    #expect(first.persistenceID == reordered.persistenceID)
    #expect(first.supersedes(reordered))
    #expect(first.isNewComputer(saved: [reordered]) == false)
  }

  @Test("origin matching ignores spelling but not scheme or port")
  func matchesOrigin() throws {
    let server = OpenCodeServer(
      url: "https://host.example:443",
      alternateURLs: ["http://192.168.1.5:4096"]
    )
    #expect(server.matchesOrigin(try #require(URL(string: "https://HOST.example/api/info"))))
    #expect(server.matchesOrigin(try #require(URL(string: "http://192.168.1.5:4096/api/event"))))
    #expect(!server.matchesOrigin(try #require(URL(string: "http://host.example/api/info"))))
    #expect(!server.matchesOrigin(try #require(URL(string: "https://host.example:8443/api/info"))))
    #expect(!server.matchesOrigin(try #require(URL(string: "https://other.example/api/info"))))
  }

  @Test("a paired server is recognized by its token shape")
  func pairingTokenShape() {
    #expect(OpenCodeServer(url: "https://h", password: "1750000000.abcdefghijklmnopqrstuvwxyz").usesPairingToken)
    #expect(!OpenCodeServer(url: "https://h", password: "hunter2").usesPairingToken)
    #expect(!OpenCodeServer(url: "https://h", password: "1750000000.short").usesPairingToken)
  }

  @Test("a machine name comes from a tailnet or Bonjour label, else the host")
  func machineNames() {
    #expect(OpenCodeServer(url: "http://basebook.tail1234.ts.net:4096").defaultName == "basebook")
    #expect(OpenCodeServer(url: "http://basebook.local:4096").defaultName == "basebook")
    #expect(OpenCodeServer(url: "http://192.168.1.5:4096").defaultName == "192.168.1.5:4096")
    #expect(OpenCodeServer.machineName("host:4096") == "host:4096")
  }

  @Test("a person's name wins over the derived one")
  func displayName() {
    let named = OpenCodeServer(url: "http://basebook.local:4096", name: "  Studio  ")
    #expect(named.displayName == "Studio")
    let blank = OpenCodeServer(url: "http://basebook.local:4096", name: "   ")
    #expect(blank.displayName == "basebook")
  }
}
