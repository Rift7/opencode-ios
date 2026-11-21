import ComposableArchitecture
import Foundation
import OpenCodeCore

#if DEBUG
  /// Device-only probes for checks no simulator can answer: the local-network permission prompt and
  /// Taptic Engine feedback. Each runs only when its launch argument is present, and prints one line
  /// with no address, credential or user data.
  enum DeviceProbes {
    static let localNetworkArgument = "-localNetworkProbeURL"
    static let hapticArgument = "-hapticProbe"

    static func startIfRequested() -> Task<Void, Never>? {
      if let address = value(after: localNetworkArgument), let url = URL(string: address) {
        return Task { await localNetwork(url) }
      }
      if ProcessInfo.processInfo.arguments.contains(hapticArgument) {
        return Task { await haptics() }
      }
      return nil
    }

    /// `--console` reads a pipe, so a line must be flushed or it sits in stdout's buffer.
    private static func emit(_ line: String) {
      print(line)
      fflush(stdout)
    }

    private static func value(after argument: String) -> String? {
      let arguments = ProcessInfo.processInfo.arguments
      guard let index = arguments.firstIndex(of: argument), index + 1 < arguments.count else {
        return nil
      }
      return arguments[index + 1]
    }

    private static func localNetwork(_ url: URL) async {
      let probe = TransportProbe()
      let request = HTTPRequest(url: url, timeout: 30)
      do {
        let response = try await probe.transport.send(request)
        emit("OPENCODE_PROBE localNetwork=reachable status=\(response.status)")
      } catch let error as TransportError {
        emit("OPENCODE_PROBE localNetwork=refused reason=\(error)")
      } catch {
        emit("OPENCODE_PROBE localNetwork=unreachable reason=\(classification(error))")
      }
    }

    /// The URLError code only: a description could carry the address.
    private static func classification(_ error: any Error) -> String {
      if error is CancellationError { return "cancelled" }
      if let urlError = error as? URLError { return "URLError \(urlError.code.rawValue)" }
      return String(describing: type(of: error))
    }

    private static func haptics() async {
      let client = HapticsProbe()
      for haptic in Haptic.allCases {
        client.play(haptic)
        emit("OPENCODE_PROBE haptic=\(haptic.rawValue)")
        try? await Task.sleep(for: .milliseconds(750))
      }
      emit("OPENCODE_PROBE haptic=done")
    }

    private struct TransportProbe {
      @Dependency(\.httpTransport) var transport
    }

    private struct HapticsProbe {
      @Dependency(\.haptics) var client

      func play(_ haptic: Haptic) {
        client.play(haptic)
      }
    }
  }
#endif
