import Foundation
import OpenCodeCore
import OpenCodeServer
import OpenCodeTestSupport
import Testing

@Suite("Shared keys")
struct SharedStoreTests {
  private func makeStore() -> SharedStore {
    SharedStore(defaults: InMemoryStorage(), keychain: InMemoryStorage())
  }

  @Test("the registry lists every foundation key")
  func registryIsComplete() {
    #expect(
      Set(SharedKeys.names) == [
        "return-key-sends", "sidebar-shown", "experimental-in-app-browser",
        "file-viewer-wraps-lines", "appearance-color-scheme", "onboarding-completed",
        "last-viewed-session", "paired-servers",
      ]
    )
    #expect(SharedKeys.names.count == Set(SharedKeys.names).count)
  }

  @Test("every key declares the default a fresh install sees")
  func defaultsAreDeclared() {
    #expect(SharedKeys.returnKeySends.defaultValue == false)
    #expect(SharedKeys.sidebarShown.defaultValue == true)
    #expect(SharedKeys.lastViewedSession.defaultValue == nil)
    #expect(SharedKeys.pairedServers.defaultValue == nil)
    #expect(SharedKeys.experimentalInAppBrowser.defaultValue == false)
    #expect(SharedKeys.fileViewerWrapsLines.defaultValue == false)
    #expect(SharedKeys.appearanceColorScheme.defaultValue == "system")
    #expect(SharedKeys.onboardingCompleted.defaultValue == false)
    #expect(ServerSharedKeys.savedServer.defaultValue == nil)
    #expect(ServerSharedKeys.savedServers.defaultValue == [])
    #expect(ServerSharedKeys.cachedSummaries.defaultValue == [:])
  }

  @Test("server keys keep credentials in the keychain and the cache in defaults")
  func serverStorageRouting() {
    #expect(ServerSharedKeys.savedServer.storage == .keychain)
    #expect(ServerSharedKeys.savedServers.storage == .keychain)
    #expect(ServerSharedKeys.cachedSummaries.storage == .userDefaults)
    #expect(Set(SharedKeys.names).isDisjoint(with: ServerSharedKeys.names))
  }

  @Test("every key names the storage its value belongs in")
  func storageRouting() {
    #expect(SharedKeys.returnKeySends.storage == .userDefaults)
    #expect(SharedKeys.sidebarShown.storage == .userDefaults)
    #expect(SharedKeys.lastViewedSession.storage == .userDefaults)
    #expect(SharedKeys.pairedServers.storage == .keychain)
  }

  @Test("an unwritten key reads as missing, and the default is a caller decision")
  func missingIsNotFailure() {
    let store = makeStore()

    #expect(store.read(SharedKeys.returnKeySends).isMissing)
    #expect(store.result(SharedKeys.returnKeySends) == .success(false))
    #expect(store.read(SharedKeys.lastViewedSession).isMissing)
    #expect(store.result(SharedKeys.lastViewedSession) == .success(nil))
  }

  @Test("a written value survives and a delete restores the missing state")
  func roundTripAndDelete() {
    let store = makeStore()

    #expect(store.write(true, for: SharedKeys.returnKeySends) == .success)
    #expect(store.write("ses_fixture", for: SharedKeys.lastViewedSession) == .success)
    #expect(store.result(SharedKeys.returnKeySends) == .success(true))
    #expect(store.result(SharedKeys.lastViewedSession) == .success("ses_fixture"))

    #expect(store.delete(SharedKeys.returnKeySends) == .success)
    #expect(store.read(SharedKeys.returnKeySends).isMissing)
  }

  @Test("keychain-backed values never touch user defaults")
  func keychainKeysStayApart() {
    let defaults = InMemoryStorage()
    let keychain = InMemoryStorage()
    let store = SharedStore(defaults: defaults, keychain: keychain)
    let payload = Data("sealed".utf8)

    #expect(store.write(payload, for: SharedKeys.pairedServers) == .success)

    #expect(store.result(SharedKeys.pairedServers) == .success(payload))
    if case .value = keychain.read(SharedKeys.pairedServers.name) {
      // stored
    } else {
      Issue.record("expected the keychain double to hold the value")
    }
    #expect(defaults.read(SharedKeys.pairedServers.name) == .missing)
  }

  @Test("corrupt stored data is undecodable, not a failure")
  func corruptDataIsUndecodable() {
    let defaults = InMemoryStorage()
    _ = defaults.write(Data("not json".utf8), for: SharedKeys.returnKeySends.name)
    let store = SharedStore(defaults: defaults, keychain: InMemoryStorage())

    guard case .undecodable = store.read(SharedKeys.returnKeySends) else {
      Issue.record("expected undecodable")
      return
    }
    #expect(store.result(SharedKeys.returnKeySends) == .success(false))
  }

  @Test("a storage failure is never reported as a missing value")
  func failureIsNotMissing() {
    let store = SharedStore(
      defaults: FailingStorage(failure: .unavailable),
      keychain: FailingStorage(failure: .unavailable)
    )

    guard case .failure(.unavailable) = store.read(SharedKeys.sidebarShown) else {
      Issue.record("expected unavailable")
      return
    }
    #expect(store.result(SharedKeys.sidebarShown) == .failure(.unavailable))
    #expect(store.write(true, for: SharedKeys.sidebarShown) == .failure(.unavailable))
    #expect(store.delete(SharedKeys.sidebarShown) == .failure(.unavailable))
  }
}

private extension SharedRead {
  var isMissing: Bool {
    if case .missing = self { return true }
    return false
  }
}
