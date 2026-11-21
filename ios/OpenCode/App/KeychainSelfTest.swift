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

      let initiallyMissing = storage.read("probe") == .missing
      let wroteFirst = storage.write(first, for: "probe") == .success
      let readFirst = storage.read("probe") == .value(first)
      let wroteSecond = storage.write(second, for: "probe") == .success
      let readSecond = storage.read("probe") == .value(second)
      let deleted = storage.delete("probe") == .success
      let cleared = storage.read("probe") == .missing

      let passed = initiallyMissing && wroteFirst && readFirst && wroteSecond && readSecond
        && deleted && cleared
      return passed ? "passed" : "failed"
    }
  }
#endif
