import Foundation
import Synchronization

/// Byte storage keyed by a stable string. The live implementation is `UserDefaults`; secrets use
/// Keychain in a later phase and never live here.
public protocol KeyValueStorage: Sendable {
  func data(forKey key: String) -> Data?
  func setData(_ data: Data?, forKey key: String)
  func removeValue(forKey key: String)
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

  public func data(forKey key: String) -> Data? {
    defaults.data(forKey: key)
  }

  public func setData(_ data: Data?, forKey key: String) {
    if let data {
      defaults.set(data, forKey: key)
    } else {
      defaults.removeObject(forKey: key)
    }
  }

  public func removeValue(forKey key: String) {
    defaults.removeObject(forKey: key)
  }
}

/// In-memory storage for tests and previews.
public final class InMemoryStorage: KeyValueStorage, Sendable {
  private let values: Mutex<[String: Data]>

  public init(values: [String: Data] = [:]) {
    self.values = Mutex(values)
  }

  public func data(forKey key: String) -> Data? {
    values.withLock { $0[key] }
  }

  public func setData(_ data: Data?, forKey key: String) {
    values.withLock { $0[key] = data }
  }

  public func removeValue(forKey key: String) {
    _ = values.withLock { $0.removeValue(forKey: key) }
  }

  public var allKeys: [String] {
    values.withLock { $0.keys.sorted() }
  }
}
