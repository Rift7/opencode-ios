import ComposableArchitecture
import Foundation
import OpenCodeCore
import OpenCodeServer

#if DEBUG
  /// A deterministic in-app client for lifecycle UI tests. It never opens a socket; the event
  /// stream reports the handshake and then stays open until the owner cancels it.
  enum UITestFixture {
    struct Fixture: Sendable {
      var client: OpenCodeClient
      var storage: SharedStore
    }

    nonisolated static let server = OpenCodeServer(
      url: "http://fixture.invalid:4096",
      username: "opencode",
      password: "fixture-token",
      name: "Fixture"
    )

    nonisolated static let secondServer = OpenCodeServer(
      url: "http://second.invalid:4096",
      username: "opencode",
      password: "fixture-token",
      name: "Second"
    )

    nonisolated static var info: ServerInfo {
      ServerInfo(version: "0.0.0-fixture", pid: 1)
    }

    nonisolated static var projects: [ServerProject] {
      [
        ServerProject(id: "p1", name: "OpenCode", directory: "/work/opencode"),
        ServerProject(id: "p2", name: "Design", directory: "/work/design"),
      ]
    }

    nonisolated static func sessions(
      for server: OpenCodeServer,
      mode: String = "connected"
    ) -> [OpenCodeSession] {
      if mode == "connected-scroll" && server.displayName != secondServer.displayName {
        return (0..<300).map { index in
          OpenCodeSession(
            id: "scroll-session-\(index)",
            serverTitle: "Scroll session \(index)",
            projectID: index.isMultiple(of: 2) ? "p1" : "p2",
            directory: index.isMultiple(of: 2) ? "/work/opencode" : "/work/design",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000 - Double(index * 60)),
            idleMilliseconds: 1_000,
            viewedMilliseconds: 1_000
          )
        }
      }
      if server.displayName == secondServer.displayName {
        return [
          OpenCodeSession(
            id: "second-session",
            serverTitle: "Second server session",
            projectID: "p2",
            directory: "/work/design",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_300),
            idleMilliseconds: 1_000,
            viewedMilliseconds: 1_000
          )
        ]
      }
      return [
        OpenCodeSession(
          id: "alpha",
          serverTitle: "Alpha release notes",
          projectID: "p1",
          directory: "/work/opencode",
          updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
          idleMilliseconds: 2_000,
          viewedMilliseconds: 1_000
        ),
        OpenCodeSession(
          id: "beta",
          serverTitle: "Beta migration",
          projectID: "p1",
          directory: "/work/opencode",
          updatedAt: Date(timeIntervalSince1970: 1_700_000_200),
          idleMilliseconds: 1_000,
          viewedMilliseconds: 1_000
        ),
        OpenCodeSession(
          id: "gamma",
          serverTitle: "Gamma design",
          projectID: "p2",
          directory: "/work/design",
          updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
          idleMilliseconds: 3_000,
          viewedMilliseconds: 0
        ),
      ]
    }

    static func make(mode: String = "connected") -> Fixture {
      let storage = SharedStore(
        defaults: InMemoryStorage(),
        keychain: InMemoryStorage()
      )
      _ = storage.write(server, for: ServerSharedKeys.savedServer)
      _ = storage.write([server, secondServer], for: ServerSharedKeys.savedServers)

      let client = OpenCodeClient(
        health: { requested in
          if requested.displayName == secondServer.displayName { return info }
          return info
        },
        redeemPairing: { _ in throw OpenCodeClientError(.unsupported) },
        projects: { requested in
          requested.displayName == secondServer.displayName
            ? [ServerProject(id: "p2", name: "Design", directory: "/work/design")]
            : projects
        },
        sessionPage: { requested, _, _ in
          SessionPage(sessions: sessions(for: requested, mode: mode), next: nil)
        },
        getSession: { requested, id in
          guard let session = sessions(for: requested).first(where: { $0.id == id }) else {
            throw OpenCodeClientError(.status(404))
          }
          return session
        },
        activeSessionIDs: { _ in [] },
        attentionSessionIDs: { _, _, _ in [] },
        viewSession: { _, _, _ in },
        deleteSession: { _, _ in },
        events: { _, onPhase in
          AsyncThrowingStream { continuation in
            let task = Task {
              await onPhase(.connected)
              continuation.yield(.connected)
              try? await Task.sleep(for: .seconds(3_600))
            }
            continuation.onTermination = { _ in task.cancel() }
          }
        }
      )
      return Fixture(client: client, storage: storage)
    }

    static var path: NetworkPathClient {
      NetworkPathClient(
        current: { .online },
        updates: { AsyncStream { $0.finish() } },
        waitUntilAvailable: {}
      )
    }
  }
#endif
