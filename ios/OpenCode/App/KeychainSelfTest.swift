import Foundation
import OpenCodeCore

#if DEBUG
  /// UI-test hook: proves the real Keychain works in the app's own process, where the bundle has the
  /// entitlements a hostless test bundle lacks. Only runs when the launch argument is present.
  enum KeychainSelfTest {
    static let argument = "-uiTestKeychainProbe"

    static func runIfRequested() -> String? {
      guard ProcessInfo.processInfo.arguments.contains(argument) else { return nil }

      let service = "ai.opencode.migration.selftest.\(UUID().uuidString)"
      let storage = KeychainStorage(service: service)
      let first = Data("probe".utf8)
      let second = Data("probe-updated".utf8)

      let initiallyEmpty = storage.data(forKey: "probe") == nil
      storage.setData(first, forKey: "probe")
      let added = storage.data(forKey: "probe") == first
      storage.setData(second, forKey: "probe")
      let updated = storage.data(forKey: "probe") == second
      storage.removeValue(forKey: "probe")
      let cleared = storage.data(forKey: "probe") == nil

      return initiallyEmpty && added && updated && cleared ? "passed" : "failed"
    }
  }
#endif
