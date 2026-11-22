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

    nonisolated static func familyMember(_ id: String, in roots: [OpenCodeSession]) -> OpenCodeSession? {
      if id == "alpha-child" {
        return OpenCodeSession(
          id: "alpha-child",
          serverTitle: "Explore the composer",
          projectID: "p1",
          directory: "/work/opencode",
          updatedAt: Date(timeIntervalSince1970: 1_700_000_150),
          idleMilliseconds: 500,
          viewedMilliseconds: 500,
          parentID: "alpha",
          agent: "explore"
        )
      }
      return roots.first { $0.id == id }
    }

    nonisolated static func family(
      for server: OpenCodeServer,
      root: OpenCodeSession
    ) -> SessionFamily {
      var sessions = [root]
      if root.id == "alpha" {
        sessions.append(
          OpenCodeSession(
            id: "alpha-child",
            serverTitle: "Explore the composer",
            projectID: "p1",
            directory: "/work/opencode",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_150),
            idleMilliseconds: 500,
            viewedMilliseconds: 500,
            parentID: "alpha",
            agent: "explore"
          )
        )
      }
      return SessionFamily(root: root, sessions: sessions, activeSessionIDs: [])
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

    actor RequestState {
      private var settled: Set<String> = []
      private var failedOnce = false

      func isSettled(_ id: String) -> Bool { settled.contains(id) }
      func settle(_ id: String) { settled.insert(id) }

      func shouldFailFirst() -> Bool {
        if failedOnce { return false }
        failedOnce = true
        return true
      }
    }

    static func make(mode: String = "connected") -> Fixture {
      let requestState = RequestState()
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
        interruptSession: { _, _ in true },
        sessionIsActive: { _, _ in false },
        sessionFamily: { requested, root in
          family(for: requested, root: root)
        },
        pendingRequests: { _, session, _ in
          guard session.id == "alpha" else { return PendingRequests() }
          let wantsForm = mode == "connected-form"
          var result = PendingRequests()
          if wantsForm {
            if await !requestState.isSettled("form-alpha") {
              result.forms = [
                FormRequest(
                  id: "form-alpha",
                  sessionID: "alpha",
                  title: "Deploy settings",
                  fields: [
                    FormField(
                      key: "environment",
                      type: .string,
                      title: "Environment",
                      required: true,
                      options: [
                        FormOption(value: "staging", label: "Staging"),
                        FormOption(value: "production", label: "Production"),
                      ]
                    ),
                    FormField(
                      key: "confirm",
                      type: .boolean,
                      title: "Confirm deploy",
                      required: true
                    ),
                  ]
                )
              ]
            }
          } else if await !requestState.isSettled("perm-alpha") {
            result.permissions = [
              PermissionRequest(
                id: "perm-alpha",
                sessionID: "alpha",
                action: "bash",
                resources: ["rm -rf build"],
                save: ["bash"]
              )
            ]
          }
          return result
        },
        replyPermission: { _, _, id, _, _ in
          if mode == "connected-request-failure", await requestState.shouldFailFirst() {
            throw OpenCodeClientError(.status(500))
          }
          await requestState.settle(id)
        },
        replyForm: { _, _, id, _, _ in
          await requestState.settle(id)
          return .settled
        },
        cancelForm: { _, _, id, _, _ in
          await requestState.settle(id)
          return .settled
        },
        formState: { _, _, _, _ in FormState(status: .pending) },
        pendingInputs: { _, sessionID in
          guard sessionID == "alpha" else { return [] }
          return [PendingInput(id: "input-alpha", text: "Also check the logs.", delivery: .steer)]
        },
        setPendingInputDelivery: { _, _, _, _ in },
        runningShells: { _, directory in
          directory == "/work/opencode"
            ? [ServerShell(id: "shell-alpha", command: "swift test", sessionID: "alpha", isListed: true)]
            : []
        },
        shell: { _, _, id in
          ServerShell(id: id, command: "swift test", sessionID: "alpha", isListed: true)
        },
        shellOutput: { _, _, _, cursor, limit in
          let output = "Test Suite started\nAll tests passed\n"
          let size = output.utf8.count
          return ShellOutputPage(output: output, cursor: size, size: size)
        },
        stopShell: { _, _, _ in },
        runningJobs: { _, sessionID in
          sessionID == "alpha"
            ? [
              ServerJob(
                id: "job-alpha",
                kind: .codemode,
                sessionID: "alpha",
                isRunning: true
              )
            ]
            : []
        },
        cancelJob: { _, _ in },
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
