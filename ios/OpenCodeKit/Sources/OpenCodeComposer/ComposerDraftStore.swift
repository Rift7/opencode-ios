import ComposableArchitecture
import Foundation
import OpenCodeCore
import OpenCodeMedia

/// All drafts for one app, keyed by server and composer scope. The actor serializes reads and
/// writes, so a save for one session can never interleave with another's.
public actor ComposerDraftStore {
  private struct Records: Codable {
    var version: Int
    var drafts: [String: ComposerDraft]

    init(version: Int = Records.currentVersion, drafts: [String: ComposerDraft] = [:]) {
      self.version = version
      self.drafts = drafts
    }

    static let currentVersion = 1
  }

  private let storage: any KeyValueStorage
  private let storageKey: String
  private var loaded: Records?
  private var loadFailure: StorageFailure?

  public init(
    storage: any KeyValueStorage = AtomicFileStorage.defaultDrafts,
    storageKey: String = "composer-drafts"
  ) {
    self.storage = storage
    self.storageKey = storageKey
  }

  public func load(_ key: ComposerDraftKey) -> ComposerDraftLoad {
    do {
      let records = try records()
      guard let draft = records.drafts[key.storageKey] else { return .missing }
      return .found(draft)
    } catch let failure as StorageFailure {
      return .failure(failure)
    } catch {
      return .failure(.unavailable)
    }
  }

  public func save(_ draft: ComposerDraft, for key: ComposerDraftKey) -> ComposerDraftSave {
    if let problem = draft.boundedProblem() { return problem }
    do {
      var records = try records()
      records.drafts[key.storageKey] = draft
      try write(records)
      return .saved
    } catch let failure as StorageFailure {
      return .failure(failure)
    } catch {
      return .failure(.unavailable)
    }
  }

  /// Saves only when the destination does not already hold newer content. A departing transfer
  /// must not overwrite typing that reached the same key after it started.
  public func saveIfNewer(_ draft: ComposerDraft, for key: ComposerDraftKey) -> ComposerDraftSave {
    do {
      let current = try records()
      if let existing = current.drafts[key.storageKey], existing.supersedes(draft) {
        return .saved
      }
    } catch let failure as StorageFailure {
      return .failure(failure)
    } catch {
      return .failure(.unavailable)
    }
    return save(draft, for: key)
  }

  /// Removes only when the destination does not hold newer content. An empty departing snapshot
  /// must not delete typing that arrived after it.
  public func removeIfNotNewer(_ draft: ComposerDraft, for key: ComposerDraftKey) -> ComposerDraftSave {
    do {
      let current = try records()
      if let existing = current.drafts[key.storageKey], existing.supersedes(draft) {
        return .saved
      }
    } catch let failure as StorageFailure {
      return .failure(failure)
    } catch {
      return .failure(.unavailable)
    }
    return remove(key)
  }

  /// A New Session draft whose created session key is missing or stale. The destination is written
  /// before the source is removed, so a failed migration never destroys the only copy.
  public func recoverCreated(
    sessionID: String,
    destination: ComposerDraftKey
  ) -> ComposerDraftLoad {
    do {
      let records = try records()
      let prefix = "\(destination.serverID)|"
      guard let source = records.drafts.first(where: { storageKey, draft in
        storageKey.hasPrefix(prefix)
          && storageKey != destination.storageKey
          && draft.createdSessionID == sessionID
      }) else { return .missing }
      guard let sourceKey = Self.key(from: source.key, serverID: destination.serverID) else {
        return .missing
      }
      let migration = migrate(source.value, from: sourceKey, to: destination)
      return .foundFromSource(source.value, migration)
    } catch let failure as StorageFailure {
      return .failure(failure)
    } catch {
      return .failure(.unavailable)
    }
  }

  public func migrate(
    _ draft: ComposerDraft,
    from source: ComposerDraftKey,
    to destination: ComposerDraftKey
  ) -> ComposerDraftMigration {
    do {
      // A newer save may have reached the destination while migration was pending. Never overwrite
      // it with the older source snapshot; only remove the now-redundant source.
      let current = try records()
      if current.drafts[destination.storageKey].map({ !$0.supersedes(draft) }) ?? true {
        let saved = save(draft, for: destination)
        switch saved {
        case .saved:
          break
        case .tooLarge:
          return .destinationFailed(.encoding)
        case .failure(let failure):
          return .destinationFailed(failure)
        }
      }
    } catch let failure as StorageFailure {
      return .destinationFailed(failure)
    } catch {
      return .destinationFailed(.unavailable)
    }
    let removed = remove(source)
    switch removed {
    case .saved:
      return .migrated
    case .tooLarge:
      return .sourceRetained(.encoding)
    case .failure(let failure):
      return .sourceRetained(failure)
    }
  }

  private static func key(from storageKey: String, serverID: String) -> ComposerDraftKey? {
    let prefix = "\(serverID)|"
    guard storageKey.hasPrefix(prefix) else { return nil }
    let token = storageKey.dropFirst(prefix.count)
    if token.hasPrefix("session:") {
      return ComposerDraftKey(
        serverID: serverID,
        scope: .session(String(token.dropFirst("session:".count)))
      )
    }
    if token.hasPrefix("new:") {
      return ComposerDraftKey(
        serverID: serverID,
        scope: .newSession(directory: String(token.dropFirst("new:".count)))
      )
    }
    return nil
  }

  /// Every attachment reference a persisted draft, failed send or outbound record still owns for
  /// one server. Cleanup uses this union so another session's draft can keep a file alive.
  public func referencedStoredNames(serverID: String) -> Result<Set<String>, StorageFailure> {
    do {
      let records = try records()
      let prefix = "\(serverID)|"
      var names: Set<String> = []
      for (key, draft) in records.drafts where key.hasPrefix(prefix) {
        for attachment in draft.attachments where !attachment.transfer.isUploaded {
          names.insert(attachment.storedName)
        }
        for failed in draft.failedSends {
          for attachment in failed.attachments where !attachment.transfer.isUploaded {
            names.insert(attachment.storedName)
          }
        }
        for outbound in draft.outbound {
          for attachment in outbound.attachments where !attachment.transfer.isUploaded {
            names.insert(attachment.storedName)
          }
        }
      }
      return .success(names)
    } catch let failure as StorageFailure {
      return .failure(failure)
    } catch {
      return .failure(.unavailable)
    }
  }

  /// Merges one attachment transfer into the persisted draft that owns it without replacing newer
  /// text, quotes or other attachments. A record where the attachment was removed or sent is a
  /// no-op.
  public func applyAttachmentTransfer(
    key: ComposerDraftKey,
    attachmentID: String,
    transfer: MediaTransfer
  ) -> ComposerDraftSave {
    do {
      var records = try records()
      guard var draft = records.drafts[key.storageKey],
        let index = draft.attachments.firstIndex(where: { $0.id == attachmentID })
      else { return .saved }
      draft.attachments[index].transfer = transfer
      records.drafts[key.storageKey] = draft
      try write(records)
      return .saved
    } catch let failure as StorageFailure {
      return .failure(failure)
    } catch {
      return .failure(.unavailable)
    }
  }

  public func remove(_ key: ComposerDraftKey) -> ComposerDraftSave {
    do {
      var records = try records()
      guard records.drafts.removeValue(forKey: key.storageKey) != nil else { return .saved }
      try write(records)
      return .saved
    } catch let failure as StorageFailure {
      return .failure(failure)
    } catch {
      return .failure(.unavailable)
    }
  }

  /// Flush is immediate: the reducer owns the 500 ms debounce, so a background transition can
  /// write the current snapshot without waiting for it.
  public func flush() {
    guard let loaded, loaded.version == Records.currentVersion else { return }
    try? write(loaded)
  }

  private func records() throws -> Records {
    if let loadFailure { throw loadFailure }
    if let loaded { return loaded }
    switch storage.read(storageKey) {
    case .missing:
      let empty = Records()
      loaded = empty
      return empty
    case .failure(let failure):
      loadFailure = failure
      throw failure
    case .value(let data):
      do {
        let decoded = try JSONDecoder().decode(Records.self, from: data)
        guard decoded.version == Records.currentVersion else {
          // A newer or unknown format is not trusted or silently overwritten.
          loadFailure = .encoding
          throw StorageFailure.encoding
        }
        loaded = decoded
        return decoded
      } catch {
        loadFailure = .encoding
        throw StorageFailure.encoding
      }
    }
  }

  private func write(_ records: Records) throws {
    let data: Data
    do {
      data = try JSONEncoder().encode(records)
    } catch {
      throw StorageFailure.encoding
    }
    switch storage.write(data, for: storageKey) {
    case .success:
      loaded = records
      loadFailure = nil
    case .failure(let failure):
      throw failure
    }
  }
}

/// One JSON file in Application Support, written atomically. Every operation reports a storage
/// outcome; a locked or full volume is never mistaken for a successful save.
public struct AtomicFileStorage: KeyValueStorage {
  private let url: URL

  public init(url: URL) {
    self.url = url
  }

  public static var defaultDrafts: AtomicFileStorage {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    let directory = base.appendingPathComponent("OpenCode", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return AtomicFileStorage(url: directory.appendingPathComponent("composer-drafts.json"))
  }

  public func read(_ key: String) -> StorageRead {
    guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
    do {
      return .value(try Data(contentsOf: url))
    } catch {
      return .failure(.unavailable)
    }
  }

  public func write(_ data: Data, for key: String) -> StorageWrite {
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try data.write(to: url, options: .atomic)
      return .success
    } catch {
      return .failure(.unavailable)
    }
  }

  public func delete(_ key: String) -> StorageWrite {
    do {
      if FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
      }
      return .success
    } catch {
      return .failure(.unavailable)
    }
  }
}

/// The reducer's seam to draft storage. Tests inject scripted outcomes instead of touching disk.
public struct ComposerDraftClient: Sendable {
  public var load: @Sendable (ComposerDraftKey) async -> ComposerDraftLoad
  public var save: @Sendable (ComposerDraft, ComposerDraftKey) async -> ComposerDraftSave
  public var remove: @Sendable (ComposerDraftKey) async -> ComposerDraftSave
  /// Saves unless the destination already holds a newer revision.
  public var saveIfNewer: @Sendable (ComposerDraft, ComposerDraftKey) async -> ComposerDraftSave
  /// Removes unless the destination holds newer content than the empty snapshot.
  public var removeIfNotNewer:
    @Sendable (ComposerDraft, ComposerDraftKey) async -> ComposerDraftSave
  /// A departing session's conditional save. Defaults to `saveIfNewer`.
  public var saveDeparting: @Sendable (ComposerDraft, ComposerDraftKey) async -> ComposerDraftSave
  /// A departing session's conditional removal. Defaults to `removeIfNotNewer`.
  public var removeDeparting: @Sendable (ComposerDraft, ComposerDraftKey) async -> ComposerDraftSave
  /// Loads a created session's draft from the New Session key when the destination key is missing,
  /// after trying a destination-first migration.
  public var recoverCreated: @Sendable (String, ComposerDraftKey) async -> ComposerDraftLoad
  public var migrate:
    @Sendable (ComposerDraft, ComposerDraftKey, ComposerDraftKey) async -> ComposerDraftMigration
  public var applyAttachmentTransfer:
    @Sendable (ComposerDraftKey, String, MediaTransfer) async -> ComposerDraftSave
  public var referencedStoredNames:
    @Sendable (String) async -> Result<Set<String>, StorageFailure>
  public var flush: @Sendable () async -> Void

  public init(
    load: @escaping @Sendable (ComposerDraftKey) async -> ComposerDraftLoad = { _ in .missing },
    save: @escaping @Sendable (ComposerDraft, ComposerDraftKey) async -> ComposerDraftSave = { _, _ in
      .saved
    },
    remove: @escaping @Sendable (ComposerDraftKey) async -> ComposerDraftSave = { _ in .saved },
    saveIfNewer: (@Sendable (ComposerDraft, ComposerDraftKey) async -> ComposerDraftSave)? = nil,
    removeIfNotNewer: (@Sendable (ComposerDraft, ComposerDraftKey) async -> ComposerDraftSave)? = nil,
    saveDeparting: (@Sendable (ComposerDraft, ComposerDraftKey) async -> ComposerDraftSave)? = nil,
    removeDeparting: (@Sendable (ComposerDraft, ComposerDraftKey) async -> ComposerDraftSave)? = nil,
    recoverCreated: @escaping @Sendable (String, ComposerDraftKey) async -> ComposerDraftLoad = {
      _, _ in .missing
    },
    migrate: @escaping @Sendable (ComposerDraft, ComposerDraftKey, ComposerDraftKey) async ->
      ComposerDraftMigration = { _, _, _ in .migrated },
    applyAttachmentTransfer: @escaping @Sendable (
      ComposerDraftKey, String, MediaTransfer
    ) async -> ComposerDraftSave = { _, _, _ in .saved },
    referencedStoredNames: @escaping @Sendable (String) async -> Result<Set<String>, StorageFailure> = {
      _ in .failure(.unavailable)
    },
    flush: @escaping @Sendable () async -> Void = {}
  ) {
    self.load = load
    self.save = save
    self.remove = remove
    self.saveIfNewer = saveIfNewer ?? save
    self.removeIfNotNewer = removeIfNotNewer ?? { _, key in await remove(key) }
    self.saveDeparting = saveDeparting ?? self.saveIfNewer
    self.removeDeparting = removeDeparting ?? self.removeIfNotNewer
    self.recoverCreated = recoverCreated
    self.migrate = migrate
    self.applyAttachmentTransfer = applyAttachmentTransfer
    self.referencedStoredNames = referencedStoredNames
    self.flush = flush
  }

  public static func live(store: ComposerDraftStore) -> ComposerDraftClient {
    ComposerDraftClient(
      load: { await store.load($0) },
      save: { await store.save($0, for: $1) },
      remove: { await store.remove($0) },
      saveIfNewer: { await store.saveIfNewer($0, for: $1) },
      removeIfNotNewer: { await store.removeIfNotNewer($0, for: $1) },
      saveDeparting: { await store.saveIfNewer($0, for: $1) },
      removeDeparting: { await store.removeIfNotNewer($0, for: $1) },
      recoverCreated: { await store.recoverCreated(sessionID: $0, destination: $1) },
      migrate: { await store.migrate($0, from: $1, to: $2) },
      applyAttachmentTransfer: {
        await store.applyAttachmentTransfer(key: $0, attachmentID: $1, transfer: $2)
      },
      referencedStoredNames: { await store.referencedStoredNames(serverID: $0) },
      flush: { await store.flush() }
    )
  }
}

extension ComposerDraftClient: DependencyKey {
  public static let liveValue: ComposerDraftClient = {
    let store = ComposerDraftStore()
    return .live(store: store)
  }()

  public static let testValue = ComposerDraftClient()
}

extension DependencyValues {
  public var composerDrafts: ComposerDraftClient {
    get { self[ComposerDraftClient.self] }
    set { self[ComposerDraftClient.self] = newValue }
  }
}
