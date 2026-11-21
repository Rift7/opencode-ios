import Foundation
import OpenCodeCore
import OpenCodeTestSupport
import Testing

@Suite("Keychain outcomes")
struct KeychainFailureTests {
  @Test("a denied keychain read is a failure, not an empty store")
  func deniedReadIsFailure() {
    let storage = KeychainStorage(
      service: "ai.opencode.migration.tests.denied",
      operations: ScriptedKeychainOperations(read: .failure(.denied))
    )

    #expect(storage.read("probe") == .failure(.denied))
  }

  @Test("a missing keychain item is reported as missing")
  func missingIsMissing() {
    let storage = KeychainStorage(
      service: "ai.opencode.migration.tests.missing",
      operations: ScriptedKeychainOperations(read: .missing)
    )

    #expect(storage.read("probe") == .missing)
  }

  @Test("a failed keychain write is not reported as success")
  func failedWriteIsFailure() {
    let storage = KeychainStorage(
      service: "ai.opencode.migration.tests.write",
      operations: ScriptedKeychainOperations(write: .failure(.unavailable))
    )

    #expect(storage.write(Data("value".utf8), for: "probe") == .failure(.unavailable))
  }

  @Test("a failed keychain delete is not reported as success")
  func failedDeleteIsFailure() {
    let storage = KeychainStorage(
      service: "ai.opencode.migration.tests.delete",
      operations: ScriptedKeychainOperations(delete: .failure(.other(-1)))
    )

    #expect(storage.delete("probe") == .failure(.other(-1)))
  }

  @Test("a keychain-backed shared key surfaces access failures")
  func sharedKeySurfacesFailure() {
    let storage = KeychainStorage(
      service: "ai.opencode.migration.tests.shared",
      operations: ScriptedKeychainOperations(
        read: .failure(.denied),
        write: .failure(.denied)
      )
    )
    let store = SharedStore(defaults: InMemoryStorage(), keychain: storage)

    guard case .failure(.denied) = store.read(SharedKeys.pairedServers) else {
      Issue.record("expected denied")
      return
    }
    #expect(store.result(SharedKeys.pairedServers) == .failure(.denied))
    #expect(store.write(Data("value".utf8), for: SharedKeys.pairedServers) == .failure(.denied))
  }

  @Test("platform statuses map to actionable failures")
  func statusMapping() {
    #expect(SecItemKeychainOperations.classify(errSecMissingEntitlement) == .denied)
    #expect(SecItemKeychainOperations.classify(errSecAuthFailed) == .denied)
    #expect(SecItemKeychainOperations.classify(errSecInteractionNotAllowed) == .unavailable)
    #expect(SecItemKeychainOperations.classify(errSecNotAvailable) == .unavailable)
    #expect(SecItemKeychainOperations.classify(errSecSuccess) == .other(errSecSuccess))
  }
}
