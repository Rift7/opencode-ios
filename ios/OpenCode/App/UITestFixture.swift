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

    static let server = OpenCodeServer(
      url: "http://fixture.invalid:4096",
      username: "opencode",
      password: "fixture-token",
      name: "Fixture"
    )

    nonisolated static var info: ServerInfo {
      ServerInfo(version: "0.0.0-fixture", pid: 1)
    }

    nonisolated static var projects: [ServerProject] {
      [ServerProject(id: "p1", name: "OpenCode", directory: "/work/opencode")]
    }

    static func make() -> Fixture {
      let storage = SharedStore(
        defaults: InMemoryStorage(),
        keychain: InMemoryStorage()
      )
      _ = storage.write(server, for: ServerSharedKeys.savedServer)
      _ = storage.write([server], for: ServerSharedKeys.savedServers)

      let client = OpenCodeClient(
        health: { _ in info },
        redeemPairing: { _ in throw OpenCodeClientError(.unsupported) },
        projects: { _ in projects },
        sessionPage: { _, _, _ in throw OpenCodeClientError(.unsupported) },
        getSession: { _, _ in throw OpenCodeClientError(.unsupported) },
        activeSessionIDs: { _ in throw OpenCodeClientError(.unsupported) },
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
