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
          if let member = familyMember(id, in: sessions(for: requested)) {
            return member
          }
          throw OpenCodeClientError(.status(404))
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
        transcript: { _, sessionID, limit in
          transcriptPage(for: sessionID, mode: mode, limit: limit)
        },
        transcriptHistory: { _, sessionID, cursor in
          transcriptHistory(for: sessionID, mode: mode, cursor: cursor)
        },
        events: { _, onPhase in
          AsyncThrowingStream { continuation in
            let task = Task {
              await onPhase(.connected)
              continuation.yield(.connected)
              if mode == "connected-transcript-stream" || mode == "connected-transcript-growth" {
                if mode == "connected-transcript-stream" {
                  continuation.yield(.executionStarted(sessionID: "alpha"))
                }
                let messageID = mode == "connected-transcript-growth" ? "growth-live" : "stream-live"
                continuation.yield(
                  .contentBatch(
                    sessionID: "alpha",
                    events: [.textStarted(messageID: messageID, ordinal: 0)]
                  )
                )
                let count = mode == "connected-transcript-growth" ? 2_000 : 600
                for index in 0..<count {
                  guard !Task.isCancelled else { return }
                  let token: String
                  if mode == "connected-transcript-growth" {
                    if index == 400 {
                      token = "\n\n### Anchor Marker\n\n"
                    } else if index > 0, index.isMultiple(of: 80) {
                      token = "\n\n## Section \(index / 80)\n"
                    } else if index > 0, index.isMultiple(of: 40) {
                      token = "\n\n- point \(index)\n"
                    } else {
                      token = "token\(index) "
                    }
                  } else {
                    token = "token\(index) "
                  }
                  continuation.yield(
                    .contentBatch(
                      sessionID: "alpha",
                      events: [
                        .textDelta(
                          messageID: messageID,
                          ordinal: 0,
                          delta: token,
                          accumulatedText: nil
                        )
                      ]
                    )
                  )
                  try? await Task.sleep(for: .milliseconds(20))
                }
                if mode == "connected-transcript-stream" {
                  continuation.yield(.executionEnded(sessionID: "alpha"))
                }
              }
              try? await Task.sleep(for: .seconds(3_600))
            }
            continuation.onTermination = { _ in task.cancel() }
          }
        }
      )
      return Fixture(client: client, storage: storage)
    }



    // MARK: Transcript fixtures

    nonisolated static func transcriptPage(
      for sessionID: String,
      mode: String,
      limit: Int
    ) -> TranscriptPage {
      if sessionID == "alpha-child" {
        return TranscriptPage(
          items: [
            .userText(
              id: "child-user",
              text: "Explore how the composer queues a message.",
              source: .parentAgent,
              quotes: []
            ),
            .assistantMarkdown(
              id: "child-reply",
              text: "The composer stores queued inputs in the inbox and shows them above the field.",
              inProgress: false
            ),
          ]
        )
      }
      if sessionID == "beta" {
        return TranscriptPage(
          items: [
            .userText(id: "beta-user", text: "Summarize the migration.", source: nil, quotes: []),
            .assistantMarkdown(
              id: "beta-reply",
              text: "The native app now includes the transcript, with Markdown and tool disclosures.",
              inProgress: false
            ),
          ]
        )
      }
      guard sessionID == "alpha" else {
        return TranscriptPage(
          items: [
            .info(id: "info-empty", text: "No messages in this fixture session."),
          ]
        )
      }
      switch mode {
      case "connected-transcript-long":
        return TranscriptPage(items: longTranscriptItems(count: 1_000))
      case "connected-transcript-older":
        let all = longTranscriptItems(count: 200)
        let newest = Array(all.suffix(30))
        return TranscriptPage(items: newest, next: "older-1")
      case "connected-transcript-stream":
        return TranscriptPage(
          items: [.userText(id: "stream-user", text: "Stream six hundred tokens.", source: nil, quotes: [])]
        )
      case "connected-transcript-growth":
        return TranscriptPage(
          items: [.userText(id: "growth-user", text: "Stream many tokens.", source: nil, quotes: [])]
        )
      default:
        return TranscriptPage(items: richTranscriptItems())
      }
    }

    nonisolated static func transcriptHistory(
      for sessionID: String,
      mode: String,
      cursor: String?
    ) -> TranscriptPage {
      guard sessionID == "alpha", mode == "transcript-older", cursor == "older-1" else {
        return TranscriptPage(items: [])
      }
      let all = longTranscriptItems(count: 200)
      let older = Array(all.dropLast(30))
      return TranscriptPage(items: older, next: nil)
    }

    nonisolated static func richTranscriptItems() -> [TranscriptItem] {
      [
        .userText(
          id: "alpha-user-1",
          text: "Can you review the transcript implementation?",
          source: nil,
          quotes: []
        ),
        .assistantMarkdown(
          id: "alpha-reply-1",
          text: """
            ## Transcript review

            The renderer keeps **stable part identities** and draws:

            - headings, lists and quotes
            - fenced code
            - tables

            | Surface | State |
            | --- | --- |
            | Rows | Ready |
            | Markdown | Ready |

            ```swift
            Text(MarkdownParser.inline(text))
            ```

            [OpenCode](https://example.com/docs)

            ![Diagram](https://example.com/diagram.png)
            """,
          inProgress: false
        ),
        .tool(
          id: "alpha-tool-read",
          call: TranscriptToolCall(
            callID: "tool-read",
            messageID: "alpha-reply-1",
            name: "read",
            status: .completed,
            input: .object(["path": .string("ios/OpenCode/Transcript/TranscriptView.swift")]),
            output: ["Read 240 lines"]
          )
        ),
        .tool(
          id: "alpha-tool-shell",
          call: TranscriptToolCall(
            callID: "tool-shell",
            messageID: "alpha-reply-1",
            name: "shell",
            status: .completed,
            input: .object(["command": .string("swift test --package-path ios/OpenCodeKit")]),
            output: ["All tests passed"],
            metadata: ["exit": .number(0)]
          )
        ),
        .notice(
          id: "alpha-notice-shell",
          text: "swift test finished",
          isError: false,
          kind: TranscriptNoticeKind(source: .shell, outcome: .finished),
          agent: nil
        ),
        .userText(
          id: "alpha-user-2",
          text: "Please keep the reading position.",
          source: nil,
          quotes: [
            TranscriptQuote(
              text: "no forced scrolling while reading older content",
              comment: "This is the part I care about."
            )
          ]
        ),
        .assistantMarkdown(
          id: "alpha-reply-2",
          text: """
            The list follows only while the reader is at the end. Scrolling up reveals **Jump to Latest** and keeps the anchor through streaming updates.

            An inline formula `E = mc²` stays readable as text; display math renders its source:

            $$
            \\int_0^1 x^2 dx = \\frac{1}{3}
            $$
            """,
          inProgress: false
        ),
        .compaction(
          id: "alpha-compaction",
          info: TranscriptCompaction(
            status: .completed,
            summary: "Earlier exploration was compacted. The transcript code, tests and parity notes remain the reference.",
            inputTokens: 12_400,
            outputTokens: 420
          )
        ),
        .modelSwitch(
          id: "alpha-model",
          model: TranscriptModelRef(id: "claude-opus-5.5", providerID: "anthropic"),
          previous: nil,
          name: "Claude Opus 5.5"
        ),
      ]
    }

    nonisolated static func longTranscriptItems(count: Int) -> [TranscriptItem] {
      (0..<count).map { index in
        if index.isMultiple(of: 2) {
          return .userText(
            id: "long-user-\(index)",
            text: "Message \(index): keep the transcript stable while scrolling.",
            source: nil,
            quotes: []
          )
        }
        return .assistantMarkdown(
          id: "long-reply-\(index)",
          text: "Reply \(index): stable row identity keeps the reader in place. " + String(repeating: "Detail. ", count: 6),
          inProgress: false
        )
      }
    }

    nonisolated static func streamingTranscriptItems() -> [TranscriptItem] {
      let tokens = (0..<600).map { "token\($0)" }.joined(separator: " ")
      return [
        .userText(id: "stream-user", text: "Stream six hundred tokens.", source: nil, quotes: []),
        .assistantMarkdown(
          id: "stream-reply",
          text: tokens + " FINAL-TAIL",
          inProgress: false
        ),
      ]
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
