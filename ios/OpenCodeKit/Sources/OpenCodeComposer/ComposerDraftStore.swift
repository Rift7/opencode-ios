import ComposableArchitecture
import Foundation
import OpenCodeCore

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
  public var flush: @Sendable () async -> Void

  public init(
    load: @escaping @Sendable (ComposerDraftKey) async -> ComposerDraftLoad = { _ in .missing },
    save: @escaping @Sendable (ComposerDraft, ComposerDraftKey) async -> ComposerDraftSave = { _, _ in
      .saved
    },
    remove: @escaping @Sendable (ComposerDraftKey) async -> ComposerDraftSave = { _ in .saved },
    flush: @escaping @Sendable () async -> Void = {}
  ) {
    self.load = load
    self.save = save
    self.remove = remove
    self.flush = flush
  }

  public static func live(store: ComposerDraftStore) -> ComposerDraftClient {
    ComposerDraftClient(
      load: { await store.load($0) },
      save: { await store.save($0, for: $1) },
      remove: { await store.remove($0) },
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
