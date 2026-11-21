import Foundation
import Synchronization

/// Why a storage operation failed. Kept small and typed so a caller cannot mistake an access
/// failure for an empty store.
public enum StorageFailure: Error, Equatable, Sendable {
  /// The backing store is not available right now (for example a locked keychain).
  case unavailable
  /// Access was refused: missing entitlement or failed authentication.
  case denied
  /// The value could not be represented for storage.
  case encoding
  /// Any other platform status. The number is a diagnostic, never user data.
  case other(Int32)
}

public enum StorageRead: Equatable, Sendable {
  case value(Data)
  case missing
  case failure(StorageFailure)
}

public enum StorageWrite: Equatable, Sendable {
  case success
  case failure(StorageFailure)
}

/// Byte storage keyed by a stable string. Every operation reports its outcome explicitly: a missing
/// item and a failed read are different answers.
public protocol KeyValueStorage: Sendable {
  func read(_ key: String) -> StorageRead
  func write(_ data: Data, for key: String) -> StorageWrite
  func delete(_ key: String) -> StorageWrite
}

/// `UserDefaults`-backed storage. The suite name is supplied by the caller so the app and tests
/// never share a domain.
public struct UserDefaultsStorage: KeyValueStorage {
  private let suiteName: String?

  public init(suiteName: String? = nil) {
    self.suiteName = suiteName
  }

  private var defaults: UserDefaults {
    if let suiteName, let scoped = UserDefaults(suiteName: suiteName) {
      return scoped
    }
    return .standard
  }

  public func read(_ key: String) -> StorageRead {
    guard let data = defaults.data(forKey: key) else { return .missing }
    return .value(data)
  }

  public func write(_ data: Data, for key: String) -> StorageWrite {
    defaults.set(data, forKey: key)
    return .success
  }

  public func delete(_ key: String) -> StorageWrite {
    defaults.removeObject(forKey: key)
    return .success
  }
}

/// In-memory storage for tests and previews.
public final class InMemoryStorage: KeyValueStorage, Sendable {
  private let values: Mutex<[String: Data]>

  public init(values: [String: Data] = [:]) {
    self.values = Mutex(values)
  }

  public func read(_ key: String) -> StorageRead {
    values.withLock { $0[key] }.map(StorageRead.value) ?? .missing
  }

  public func write(_ data: Data, for key: String) -> StorageWrite {
    values.withLock { $0[key] = data }
    return .success
  }

  public func delete(_ key: String) -> StorageWrite {
    _ = values.withLock { $0.removeValue(forKey: key) }
    return .success
  }

  public var allKeys: [String] {
    values.withLock { $0.keys.sorted() }
  }
}
