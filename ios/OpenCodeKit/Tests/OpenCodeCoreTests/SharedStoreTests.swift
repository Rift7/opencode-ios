import Foundation
import OpenCodeCore
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
        "return-key-sends", "sidebar-shown", "last-viewed-session", "paired-servers",
      ]
    )
  }

  @Test("an unwritten key returns its declared default")
  func defaultsApply() {
    let store = makeStore()

    #expect(store.value(SharedKeys.returnKeySends) == false)
    #expect(store.value(SharedKeys.sidebarShown) == true)
    #expect(store.value(SharedKeys.lastViewedSession) == nil)
    #expect(store.value(SharedKeys.pairedServers) == nil)
  }

  @Test("a written value survives and a reset restores the default")
  func roundTripAndReset() {
    let store = makeStore()

    store.set(true, for: SharedKeys.returnKeySends)
    store.set("ses_fixture", for: SharedKeys.lastViewedSession)
    #expect(store.value(SharedKeys.returnKeySends) == true)
    #expect(store.value(SharedKeys.lastViewedSession) == "ses_fixture")

    store.reset(SharedKeys.returnKeySends)
    #expect(store.value(SharedKeys.returnKeySends) == false)
  }

  @Test("keychain-backed values never touch user defaults")
  func keychainKeysStayApart() {
    let defaults = InMemoryStorage()
    let keychain = InMemoryStorage()
    let store = SharedStore(defaults: defaults, keychain: keychain)
    let payload = Data("sealed".utf8)

    store.set(payload, for: SharedKeys.pairedServers)

    #expect(store.value(SharedKeys.pairedServers) == payload)
    #expect(keychain.data(forKey: SharedKeys.pairedServers.name) != nil)
    #expect(defaults.data(forKey: SharedKeys.pairedServers.name) == nil)
  }

  @Test("corrupt stored data falls back to the default")
  func corruptDataFallsBack() {
    let defaults = InMemoryStorage()
    defaults.setData(Data("not json".utf8), forKey: SharedKeys.returnKeySends.name)
    let store = SharedStore(defaults: defaults, keychain: InMemoryStorage())

    #expect(store.value(SharedKeys.returnKeySends) == false)
  }
}
