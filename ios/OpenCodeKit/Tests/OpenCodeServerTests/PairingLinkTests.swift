import Dependencies
import Foundation
import OpenCodeCore
import OpenCodeServer
import OpenCodeTestSupport
import Testing

private let code = "AbC-123_xyz"
private let box = "https://box.example"

@Suite("Pairing link")
struct PairingLinkTests {
  @Test("a JSON payload becomes a link with its addresses in order")
  func decodesPayload() throws {
    let link = try #require(
      PairingLink.decode(#"{"code":"\#(code)","urls":["https://box.example","http://10.0.0.2:4096","https://box.example/"],"name":"Anomaly Box"}"#)
    )
    #expect(link.origin == "https://box.example")
    #expect(link.alternateOrigins == ["http://10.0.0.2:4096"])
    #expect(link.candidateOrigins == ["https://box.example", "http://10.0.0.2:4096"])
    #expect(link.name == "Anomaly Box")
  }

  @Test("a blank name counts as none")
  func blankName() throws {
    let link = try #require(
      PairingLink.decode(#"{"code":"\#(code)","urls":["https://box.example"],"name":"   "}"#)
    )
    #expect(link.name == nil)
  }

  @Test("a code must be base64url")
  func rejectsInvalidCode() {
    #expect(PairingLink.decode(#"{"code":"bad code","urls":["https://box.example"]}"#) == nil)
    #expect(PairingLink.decode(#"{"code":"","urls":["https://box.example"]}"#) == nil)
    #expect(PairingLink.decode(#"{"code":"\#(code)","urls":[]}"#) == nil)
  }

  @Test("one unusable address rejects the whole code, and names it")
  func rejectsOneBadAddress() throws {
    let text = #"{"code":"\#(code)","urls":["https://box.example","https://box.example/secret"]}"#
    #expect(PairingLink.decode(text) == nil)

    let unusable = try #require(PairingLink.unusableAddress(in: text))
    #expect(unusable.address == "https://box.example/secret")
    #expect(unusable.problem == .path)
    #expect(ServerCopy.addressReason(unusable.problem) == "has a path, and the server must be at the root of its address")
  }

  @Test("credentials, query, scheme and host problems are told apart")
  func addressProblems() throws {
    func problem(_ address: String) throws -> PairingAddressProblem {
      let text = #"{"code":"\#(code)","urls":["\#(address)"]}"#
      return try #require(PairingLink.unusableAddress(in: text)).problem
    }
    #expect(try problem("https://user:pass@box.example") == .credentials)
    #expect(try problem("https://box.example/?a=1") == .query)
    #expect(try problem("ftp://box.example") == .badScheme)
    #expect(try problem("https:///path") == .noHost)
  }

  @Test("the opencode.ai pair page carries base64url JSON in its fragment")
  func decodesPairPage() throws {
    let json = #"{"code":"\#(code)","urls":["https://box.example"]}"#
    let fragment = Data(json.utf8).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    let link = try #require(PairingLink.decode("https://opencode.ai/pair#\(fragment)"))
    #expect(link.origin == "https://box.example")
    #expect(link.code == code)

    #expect(PairingLink.isPairPage("https://opencode.ai/pair"))
    #expect(PairingLink.isPairPage("https://opencode.ai/pair#broken"))
    #expect(!PairingLink.isPairPage("https://opencode.ai/other#x"))
  }

  @Test("the app's deep link carries code, addresses and a name")
  func decodesDeepLink() throws {
    let text =
      "opencode-ios://pair?code=\(code)&url=https%3A%2F%2Fbox.example&urls=%5B%22http%3A%2F%2F10.0.0.2%3A4096%22%5D&name=Box"
    let link = try #require(PairingLink.decode(text))
    #expect(link.origin == "https://box.example")
    #expect(link.alternateOrigins == ["http://10.0.0.2:4096"])
    #expect(link.name == "Box")
  }

  @Test("an unknown or credential-bearing deep-link parameter is refused")
  func rejectsUnknownDeepLinkParameters() {
    #expect(PairingLink.decode("opencode://pair?code=\(code)&url=https%3A%2F%2Fbox.example&token=x") == nil)
    #expect(PairingLink.decode("opencode://pair?code=\(code)&url=https%3A%2F%2Fbox.example&username=me") == nil)
    #expect(PairingLink.decode("opencode://pair?url=https%3A%2F%2Fbox.example") == nil)
    #expect(PairingLink.decode("opencode://pair?code=\(code)") == nil)
    #expect(PairingLink.decode("opencode://pair?code=one&code=two&url=https%3A%2F%2Fbox.example") == nil)
  }

  @Test("one /auth/connect link decodes to its origin and code")
  func decodesConnectLink() throws {
    let link = try #require(PairingLink.decode("http://10.0.0.2:4096/auth/connect/\(code)"))
    #expect(link.origin == "http://10.0.0.2:4096")
    #expect(link.code == code)
    #expect(link.alternateOrigins.isEmpty)
    #expect(PairingLink.isPairingHTTPPath("http://10.0.0.2:4096/auth/connect/\(code)"))
    #expect(PairingLink.decode("http://10.0.0.2:4096/auth/connect/\(code)?token=1") == nil)
  }

  @Test("redemption skips loopback when anything else is listed")
  func redeemOriginsSkipLoopback() throws {
    let link = try #require(
      PairingLink.decode(
        #"{"code":"\#(code)","urls":["http://127.0.0.1:4096","http://10.0.0.2:4096","http://localhost:4096"]}"#
      )
    )
    #expect(link.redeemOrigins == ["http://10.0.0.2:4096"])
    #expect(!link.isLoopback)

    let loopbackOnly = try #require(
      PairingLink.decode(#"{"code":"\#(code)","urls":["http://127.0.0.1:4096"]}"#)
    )
    #expect(loopbackOnly.isLoopback)
    #expect(loopbackOnly.redeemOrigins == ["http://127.0.0.1:4096"])
  }

  @Test("addresses that differ only by spelling redeem once")
  func redeemOriginsDeduplicate() throws {
    let link = try #require(
      PairingLink.decode(
        #"{"code":"\#(code)","urls":["https://box.example","https://BOX.example:443/","http://10.0.0.2:4096"]}"#
      )
    )
    #expect(link.redeemOrigins == ["https://box.example", "http://10.0.0.2:4096"])
  }

  @Test("a normalized link confirms and redeems the same addresses")
  func normalizedForRedemption() throws {
    let link = try #require(
      PairingLink.decode(#"{"code":"\#(code)","urls":["http://127.0.0.1:4096","http://10.0.0.2:4096"]}"#)
    )
    let normalized = link.normalizedForRedemption
    #expect(normalized.origin == "http://10.0.0.2:4096")
    #expect(normalized.alternateOrigins.isEmpty)
    #expect(normalized.code == code)
  }

  @Test("a copied code's deep link round-trips")
  func deepLinkRoundTrips() throws {
    let original = try #require(
      PairingLink.decode(
        #"{"code":"\#(code)","urls":["https://box.example","http://10.0.0.2:4096"],"name":"Anomaly Box"}"#
      )
    )
    let decoded = try #require(PairingLink.decode(original.deepLinkURL))
    #expect(decoded == original)
  }

  @Test("a code wrapped by a terminal is still read")
  func decodesCopiedText() throws {
    let text = """
      Run this on your computer:

      opencode pair --remote
      \(box)/auth/connect/\(code)
      """
    let link = try #require(PairingLink.decodeCopied(text))
    #expect(link.origin == box)
    #expect(link.code == code)
  }

  @Test("decoding never contacts a server")
  func decodingSpendsNothing() async throws {
    let session = NetworkGuard.makeSession()
    let transport = HTTPTransport(
      send: { request in
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        for (name, value) in request.headers {
          urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await session.data(for: urlRequest)
        return HTTPResponse(
          status: (response as? HTTPURLResponse)?.statusCode ?? 0,
          headers: [:],
          body: data,
          finalURL: request.url
        )
      },
      open: { _ in throw TransportError.blocked }
    )

    let decoded = await withDependencies {
      $0.httpTransport = transport
    } operation: {
      PairingLink.decode(#"{"code":"\#(code)","urls":["https://box.example"]}"#)
    }

    #expect(decoded != nil)
    #expect(NetworkGuard.requestedHosts.contains("box.example") == false)
  }

  @Test("a malformed pairing-shaped URL is still recognized as pairing")
  func recognizesPairingEndpoints() {
    #expect(PairingLink.shouldHandleOpenURL("opencode://pair?code=\(code)"))
    #expect(PairingLink.shouldHandleOpenURL("https://opencode.ai/pair#broken"))
    #expect(PairingLink.shouldHandleOpenURL("https://box.example/auth/connect/\(code)"))
    #expect(!PairingLink.shouldHandleOpenURL("https://example.com/"))
  }
}
