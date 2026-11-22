import Foundation
import OpenCodeCore

/// One address race's winner: the server at the address that answered, the health payload it
/// returned, and how many addresses were tried.
public struct ServerLinkProbe: Sendable, Equatable {
  public var server: OpenCodeServer
  public var info: ServerInfo
  public var candidates: Int
  public var elapsedMilliseconds: Int

  public init(server: OpenCodeServer, info: ServerInfo, candidates: Int, elapsedMilliseconds: Int) {
    self.server = server
    self.info = info
    self.candidates = candidates
    self.elapsedMilliseconds = elapsedMilliseconds
  }
}

/// The audited address race: every candidate is probed once, the first that answers `/api/info` as
/// this server wins, and the rest are cancelled. Addresses outside the preferred set wait briefly
/// so the address the person chose is not held up by a blackholed backup.
public enum ServerLink {
  public static let preferredHeadStart: Duration = .milliseconds(1500)

  public static func probe(
    _ server: OpenCodeServer,
    health: @escaping @Sendable (OpenCodeServer) async throws -> ServerInfo,
    clock: ClockClient = ClockClient.liveValue,
    preferredHeadStart: Duration = ServerLink.preferredHeadStart
  ) async throws -> ServerLinkProbe {
    let candidates = server.candidateURLs
    guard !candidates.isEmpty else { throw OpenCodeClientError(.invalidURL) }
    let preferred = Set(server.firstAttemptURLs)
    let started = clock.now()
    let log = AppLog(category: .network)

    let outcome: Result<ServerLinkProbe, OpenCodeClientError> = await withTaskGroup(
      of: RaceResult.self,
      returning: Result<ServerLinkProbe, OpenCodeClientError>.self
    ) { group in
      for url in candidates {
        let candidate = server.at(url: url)
        group.addTask {
          if !preferred.contains(url) {
            do {
              try await clock.sleep(preferredHeadStart)
            } catch {
              return .cancelled
            }
          }
          if Task.isCancelled { return .cancelled }
          do {
            return .success(
              ServerLinkProbe(
                server: candidate,
                info: try await health(candidate),
                candidates: candidates.count,
                elapsedMilliseconds: milliseconds(clock.now() - started)
              )
            )
          } catch let error as OpenCodeClientError {
            return .failure(error)
          } catch is CancellationError {
            return .cancelled
          } catch {
            return .failure(OpenCodeClientError(.unreachable))
          }
        }
      }

      var failures: [OpenCodeClientError] = []
      while let result = await group.next() {
        switch result {
        case .success(let probe):
          group.cancelAll()
          return .success(probe)
        case .failure(let error):
          failures.append(error)
        case .cancelled:
          continue
        }
      }
      return .failure(pairingFailureLikeSelection(failures))
    }

    switch outcome {
    case .success(let probe):
      log.event(
        .linkProbe,
        [
          LogField("candidates", .count(probe.candidates)),
          LogField("duration", .durationMilliseconds(probe.elapsedMilliseconds)),
          LogField("status", .status(200)),
        ]
      )
      return probe
    case .failure(let error):
      log.event(
        .linkProbe,
        [
          LogField("candidates", .count(candidates.count)),
          LogField("duration", .durationMilliseconds(milliseconds(clock.now() - started))),
          LogField("status", .status(error.statusCode ?? 0)),
        ]
      )
      throw error
    }
  }

  private enum RaceResult: Sendable {
    case success(ServerLinkProbe)
    case failure(OpenCodeClientError)
    case cancelled
  }

  /// A rejected sign-in is the most useful answer when no address won: retrying cannot fix it.
  private static func pairingFailureLikeSelection(
    _ failures: [OpenCodeClientError]
  ) -> OpenCodeClientError {
    failures.first { $0.statusCode == 401 }
      ?? failures.last
      ?? OpenCodeClientError(.unreachable)
  }

  private static func milliseconds(_ duration: Duration) -> Int {
    let components = duration.components
    let seconds = max(components.seconds, 0)
    let attoseconds = max(components.attoseconds, 0)
    return Int(seconds * 1_000 + attoseconds / 1_000_000_000_000_000)
  }
}
