import Foundation
import OpenCodeComposer
import OpenCodeCore
import Synchronization
import Testing

@Suite("Composer draft store")
struct ComposerDraftStoreTests {
  private final class ScriptedStorage: KeyValueStorage, Sendable {
    private struct State {
      var data: Data?
      var writes = 0
      var failingWrites: Set<Int> = []
    }
    private let state = Mutex(State())

    func read(_ key: String) -> StorageRead {
      state.withLock { $0.data.map(StorageRead.value) ?? .missing }
    }

    func write(_ data: Data, for key: String) -> StorageWrite {
      state.withLock { state in
        state.writes += 1
        if state.failingWrites.contains(state.writes) { return .failure(.unavailable) }
        state.data = data
        return .success
      }
    }

    func delete(_ key: String) -> StorageWrite { .success }

    func failWrites(_ numbers: Set<Int>) { state.withLock { $0.failingWrites = numbers } }
    func writeCount() -> Int { state.withLock { $0.writes } }
  }

  private let serverID = "server"
  private var newKey: ComposerDraftKey {
    ComposerDraftKey(serverID: serverID, scope: .newSession(directory: "/work/box"))
  }
  private var sessionKey: ComposerDraftKey {
    ComposerDraftKey(serverID: serverID, scope: .session("session-1"))
  }

  private func draft(_ text: String, created: String? = nil, outbound: Bool = false) -> ComposerDraft {
    ComposerDraft(
      text: text,
      projectDirectory: "/work/box",
      createdSessionID: created,
      outbound: outbound
        ? [ComposerOutbound(
          target: .session(id: "session-1"),
          messageID: "m1",
          text: text,
          quotes: [],
          delivery: .steer,
          revision: 1
        )]
        : [],
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
  }

  @Test("migration writes the destination before removing the source")
  func destinationFirst() async {
    let storage = ScriptedStorage()
    let store = ComposerDraftStore(storage: storage, storageKey: "drafts")
    _ = await store.save(draft("old", created: "session-1"), for: newKey)

    let result = await store.migrate(
      draft("old", created: "session-1"),
      from: newKey,
      to: sessionKey
    )
    #expect(result == .migrated)
    #expect(await store.load(newKey) == .missing)
    #expect(await store.load(sessionKey) == .found(draft("old", created: "session-1")))
  }

  @Test("a destination failure keeps the only source record")
  func destinationFailure() async {
    let storage = ScriptedStorage()
    let store = ComposerDraftStore(storage: storage, storageKey: "drafts")
    _ = await store.save(draft("old", created: "session-1"), for: newKey)
    storage.failWrites([storage.writeCount() + 1])

    let result = await store.migrate(
      draft("old", created: "session-1"),
      from: newKey,
      to: sessionKey
    )
    #expect(result == .destinationFailed(.unavailable))
    #expect(await store.load(sessionKey) == .missing)
    #expect(await store.load(newKey) == .found(draft("old", created: "session-1")))
  }

  @Test("a cleanup failure leaves both records, with the destination durable")
  func cleanupFailure() async {
    let storage = ScriptedStorage()
    let store = ComposerDraftStore(storage: storage, storageKey: "drafts")
    _ = await store.save(draft("old", created: "session-1"), for: newKey)
    storage.failWrites([storage.writeCount() + 2])

    let result = await store.migrate(
      draft("old", created: "session-1"),
      from: newKey,
      to: sessionKey
    )
    #expect(result == .sourceRetained(.unavailable))
    #expect(await store.load(sessionKey) == .found(draft("old", created: "session-1")))
    #expect(await store.load(newKey) == .found(draft("old", created: "session-1")))
  }

  @Test("a restart with only the created-session link recovers and migrates the draft")
  func restartDuringMigration() async {
    let storage = ScriptedStorage()
    let store = ComposerDraftStore(storage: storage, storageKey: "drafts")
    _ = await store.save(draft("old", created: "session-1"), for: newKey)

    let recovered = await store.recoverCreated(sessionID: "session-1", destination: sessionKey)
    guard case .foundFromSource(let source, let migration) = recovered else {
      Issue.record("expected recovery from the New Session key")
      return
    }
    #expect(source.text == "old")
    #expect(migration == .migrated)
    #expect(await store.load(sessionKey) == .found(draft("old", created: "session-1")))
    #expect(await store.load(newKey) == .missing)
  }


  @Test("recovery removes the actual source key when its directory metadata is missing")
  func recoveryUsesTheStoredSourceKey() async {
    let storage = ScriptedStorage()
    let store = ComposerDraftStore(storage: storage, storageKey: "drafts")
    _ = await store.save(
      ComposerDraft(
        text: "old",
        createdSessionID: "session-1",
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
      ),
      for: newKey
    )

    let recovered = await store.recoverCreated(sessionID: "session-1", destination: sessionKey)
    guard case .foundFromSource(_, .migrated) = recovered else {
      Issue.record("expected a successful recovery")
      return
    }
    #expect(await store.load(sessionKey) == .found(ComposerDraft(
      text: "old",
      createdSessionID: "session-1",
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )))
    #expect(await store.load(newKey) == .missing)
  }


  @Test("saveIfNewer keeps a newer destination and writes a newer source")
  func saveIfNewerFencesByRevision() async {
    let storage = ScriptedStorage()
    let store = ComposerDraftStore(storage: storage, storageKey: "drafts")
    _ = await store.save(
      ComposerDraft(text: "newer", revision: 4, updatedAt: Date(timeIntervalSince1970: 1_700_000_100)),
      for: sessionKey
    )

    let older = await store.saveIfNewer(
      ComposerDraft(text: "older", revision: 3, updatedAt: Date(timeIntervalSince1970: 1_700_000_000)),
      for: sessionKey
    )
    #expect(older == .saved)
    #expect(await store.load(sessionKey) == .found(
      ComposerDraft(text: "newer", revision: 4, updatedAt: Date(timeIntervalSince1970: 1_700_000_100))
    ))

    let newer = await store.saveIfNewer(
      ComposerDraft(text: "newest", revision: 5, updatedAt: Date(timeIntervalSince1970: 1_700_000_200)),
      for: sessionKey
    )
    #expect(newer == .saved)
    #expect(await store.load(sessionKey) == .found(
      ComposerDraft(text: "newest", revision: 5, updatedAt: Date(timeIntervalSince1970: 1_700_000_200))
    ))
  }


  @Test("a newer timestamp wins even when the older session's revision is higher")
  func saveIfNewerUsesTimestampsAcrossSessions() async {
    let storage = ScriptedStorage()
    let store = ComposerDraftStore(storage: storage, storageKey: "drafts")
    _ = await store.save(
      ComposerDraft(
        text: "newer",
        revision: 1,
        updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
      ),
      for: sessionKey
    )

    let skipped = await store.saveIfNewer(
      ComposerDraft(
        text: "older high revision",
        revision: 9,
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
      ),
      for: sessionKey
    )
    #expect(skipped == .saved)
    #expect(await store.load(sessionKey) == .found(
      ComposerDraft(
        text: "newer",
        revision: 1,
        updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
      )
    ))

    let written = await store.saveIfNewer(
      ComposerDraft(
        text: "latest",
        revision: 0,
        updatedAt: Date(timeIntervalSince1970: 1_700_000_200)
      ),
      for: sessionKey
    )
    #expect(written == .saved)
    #expect(await store.load(sessionKey) == .found(
      ComposerDraft(
        text: "latest",
        revision: 0,
        updatedAt: Date(timeIntervalSince1970: 1_700_000_200)
      )
    ))
  }

  @Test("migration compares revisions before replacing a destination")
  func migrationUsesRevisions() async {
    let storage = ScriptedStorage()
    let store = ComposerDraftStore(storage: storage, storageKey: "drafts")
    _ = await store.save(
      ComposerDraft(text: "destination", revision: 6, updatedAt: Date(timeIntervalSince1970: 1_700_000_100)),
      for: sessionKey
    )

    let skipped = await store.migrate(
      ComposerDraft(text: "source", revision: 5, updatedAt: Date(timeIntervalSince1970: 1_700_000_000)),
      from: newKey,
      to: sessionKey
    )
    #expect(skipped == .migrated)
    #expect(await store.load(sessionKey) == .found(
      ComposerDraft(text: "destination", revision: 6, updatedAt: Date(timeIntervalSince1970: 1_700_000_100))
    ))

    _ = await store.save(
      ComposerDraft(text: "newer source", revision: 7, updatedAt: Date(timeIntervalSince1970: 1_700_000_200)),
      for: newKey
    )
    let replaced = await store.migrate(
      ComposerDraft(text: "newer source", revision: 7, updatedAt: Date(timeIntervalSince1970: 1_700_000_200)),
      from: newKey,
      to: sessionKey
    )
    #expect(replaced == .migrated)
    #expect(await store.load(sessionKey) == .found(
      ComposerDraft(text: "newer source", revision: 7, updatedAt: Date(timeIntervalSince1970: 1_700_000_200))
    ))
    #expect(await store.load(newKey) == .missing)
  }

  @Test("a record written before revisions still decodes with revision zero")
  func legacyRecordDecodes() async {
    let storage = OpenCodeCore.InMemoryStorage()
    let key = "server|session:session-1"
    let legacy = """
      {"version":1,"drafts":{"\(key)":{"text":"Legacy","quotes":[],\
      "failedSends":[],"outbound":[],"updatedAt":0}}}
      """
    #expect(storage.write(Data(legacy.utf8), for: "drafts") == .success)
    let store = ComposerDraftStore(storage: storage, storageKey: "drafts")

    guard case .found(let draft) = await store.load(sessionKey) else {
      Issue.record("expected the legacy record")
      return
    }
    #expect(draft.text == "Legacy")
    #expect(draft.revision == 0)
  }

  @Test("a newer destination save is never overwritten by a pending migration")
  func newerDestinationWins() async {
    let storage = ScriptedStorage()
    let store = ComposerDraftStore(storage: storage, storageKey: "drafts")
    _ = await store.save(draft("old", created: "session-1"), for: newKey)
    _ = await store.save(draft("newer typing", created: "session-1"), for: sessionKey)

    let result = await store.migrate(
      draft("old", created: "session-1"),
      from: newKey,
      to: sessionKey
    )
    #expect(result == .migrated)
    #expect(await store.load(sessionKey) == .found(draft("newer typing", created: "session-1")))
    #expect(await store.load(newKey) == .missing)
  }
}
