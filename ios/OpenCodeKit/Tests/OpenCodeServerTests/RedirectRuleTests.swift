import Foundation
import OpenCodeCore
import Testing

@Suite("Redirect rule")
struct RedirectRuleTests {
  private let headers = ["Accept": "application/json", "Authorization": "Basic c2VjcmV0"]

  @Test("a redirect on the same origin is followed with the original headers")
  func sameOriginFollows() throws {
    let rule = HTTPRedirectRule(
      origin: try #require(HTTPOrigin(try #require(URL(string: "https://box.example/api/info")))),
      policy: .followSameOrigin,
      headers: headers
    )
    let decision = rule.decide(URLRequest(url: try #require(URL(string: "https://box.example/moved"))))
    guard case .follow(let request) = decision else {
      Issue.record("expected a follow")
      return
    }
    #expect(request.url?.absoluteString == "https://box.example/moved")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic c2VjcmV0")
  }

  @Test("a redirect to another origin is refused so credentials never travel")
  func crossOriginRefused() throws {
    let rule = HTTPRedirectRule(request: HTTPRequest(
      url: try #require(URL(string: "http://10.0.0.2:4096/api/info")),
      headers: headers,
      authorization: "Basic c2VjcmV0"
    ))
    #expect(
      rule.decide(URLRequest(url: try #require(URL(string: "http://10.0.0.3:4096/api/info"))))
        == .refuseCrossOrigin
    )
    #expect(
      rule.decide(URLRequest(url: try #require(URL(string: "https://10.0.0.2:4096/api/info"))))
        == .refuseCrossOrigin
    )
    #expect(
      rule.decide(URLRequest(url: try #require(URL(string: "http://evil.example/api/info"))))
        == .refuseCrossOrigin
    )
  }

  @Test("a policy that rejects redirects answers the 3xx itself")
  func rejectPolicyRefuses() throws {
    let rule = HTTPRedirectRule(
      origin: try #require(HTTPOrigin(try #require(URL(string: "https://box.example/auth/connect/code")))),
      policy: .reject,
      headers: headers
    )
    #expect(
      rule.decide(URLRequest(url: try #require(URL(string: "https://box.example/moved")))) == .refuse
    )
  }

  @Test("an http to https move is a different origin, so it is refused")
  func schemeChangeRefused() throws {
    let rule = HTTPRedirectRule(request: HTTPRequest(
      url: try #require(URL(string: "http://box.example/api/info"))
    ))
    #expect(
      rule.decide(URLRequest(url: try #require(URL(string: "https://box.example/api/info"))))
        == .refuseCrossOrigin
    )
  }
}
