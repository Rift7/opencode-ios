import Foundation
import OpenCodeCore
import OpenCodeServer
import Testing

@Suite("Session family discovery")
struct SessionFamilyTests {
  private let server = OpenCodeServer(
    url: "http://127.0.0.1:4110",
    username: "opencode",
    password: "test-token"
  )

  private var root: OpenCodeSession {
    OpenCodeSession(
      id: "root",
      serverTitle: "Root",
      projectID: "p1",
      directory: "/work/opencode",
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
  }

  private func familyClient(
    children: [String: [String]],
    active: String = #"{"data":{}}"#
  ) -> OpenCodeClient {
    let transport = Fixtures.transport { request, _ in
      let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)
      let path = components?.path ?? ""
      if path == "/api/session/active" {
        return Fixtures.json(active)
      }
      if path == "/api/session" {
        let parent = components?.queryItems?.first { $0.name == "parentID" }?.value ?? ""
        let ids = children[parent] ?? []
        let body = ids.map { Fixtures.session(id: $0, parentID: parent) }
        return Fixtures.json(#"{"data":[\#(body.joined(separator: ","))]}"#)
      }
      return Fixtures.json("{}", status: 404)
    }
    return OpenCodeClient.live(transport: transport, clock: .testValue)
  }

  @Test("a family walk is breadth-first, deduplicated and ignores a cycle")
  func breadthFirstAndCycle() async throws {
    let client = familyClient(children: [
      "root": ["a", "b"],
      "a": ["a-leaf", "root"],
      "b": ["shared"],
      "a-leaf": ["shared"],
      "shared": ["a"],
    ])
    let family = try await client.sessionFamily(server, root)

    #expect(family.sessions.map(\.id) == ["root", "a", "b", "a-leaf", "shared"])
    #expect(Set(family.sessions.map(\.id)).count == family.sessions.count)
    #expect(family.subagents.map(\.id) == ["a", "b", "a-leaf", "shared"])
  }

  @Test("the walk stops at 100 family sessions")
  func cap() async throws {
    let children = (0..<120).map { "child-\($0)" }
    let client = familyClient(children: ["root": children])
    let family = try await client.sessionFamily(server, root)

    #expect(family.sessions.count == 100)
    #expect(family.sessions.first?.id == "root")
  }

  @Test("a running session outside the capped walk is found through its parent")
  func runningDescendant() async throws {
    let client = familyClient(
      children: [
        "root": ["child-0"],
        "child-0": [],
        "late": [],
      ],
      active: #"{"data":{"late":{"type":"subagent"}}}"#
    )
    // The parent chain is discovered by metadata reads; with no parent the lookup ends.
    let family = try await client.sessionFamily(server, root)
    #expect(family.activeSessionIDs == ["late"])
    #expect(!family.sessions.contains { $0.id == "late" })
  }
}
