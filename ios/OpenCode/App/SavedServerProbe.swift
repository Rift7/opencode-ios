import Foundation
import OpenCodeApp
import OpenCodeCore
import OpenCodeServer

#if DEBUG
  /// Device-only probe: writes two fake servers to a disposable Keychain service and reads them
  /// through the same `AppRestoreResult` path the app uses at launch, then removes them.
  enum SavedServerProbe {
    static let argument = "-uiTestSavedServerRestoreProbe"

    static func runIfRequested() -> String? {
      guard ProcessInfo.processInfo.arguments.contains(argument) else { return nil }

      let service = "ai.opencode.migration.restoreprobe.\(UUID().uuidString)"
      let keychain = KeychainStorage(service: service)
      let store = SharedStore(defaults: InMemoryStorage(), keychain: keychain)
      let first = OpenCodeServer(url: "http://127.0.0.1:1", password: "probe-one")
      let second = OpenCodeServer(url: "http://127.0.0.1:2", password: "probe-two")

      let wrote = ServerWriteTransaction.save(server: first, servers: [first, second], store: store)
      let restored = AppRestoreResult.read(store)
      _ = ServerWriteTransaction.remove(server: nil, servers: [], store: store)

      guard case .success = wrote, case .restored(let server, let servers, _, _) = restored else {
        return "failed"
      }
      return server == first && servers == [first, second] ? "passed" : "failed"
    }
  }
#endif
