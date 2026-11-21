import Foundation

/// Where a shared value lives. Credentials and paired servers belong in the keychain; preferences
/// belong in user defaults.
public enum SharedStorage: Sendable {
  case userDefaults
  case keychain
}

/// A typed value with a default. Reading a key that was never written returns `defaultValue`, so a
/// fresh install behaves the same as a reset one.
public struct SharedKey<Value: Codable & Sendable>: Sendable {
  public let name: String
  public let defaultValue: Value
  public let storage: SharedStorage

  public init(name: String, defaultValue: Value, storage: SharedStorage) {
    self.name = name
    self.defaultValue = defaultValue
    self.storage = storage
  }
}

/// Reads and writes shared values through the storage the key names. Decoding failures fall back to
/// the default rather than propagating, because a stale or corrupt value must not block launch.
public struct SharedStore: Sendable {
  private let defaults: any KeyValueStorage
  private let keychain: any KeyValueStorage

  public init(defaults: any KeyValueStorage, keychain: any KeyValueStorage) {
    self.defaults = defaults
    self.keychain = keychain
  }

  public func value<Value>(_ key: SharedKey<Value>) -> Value {
    guard
      let data = storage(for: key).data(forKey: key.name),
      let decoded = try? JSONDecoder().decode(Value.self, from: data)
    else {
      return key.defaultValue
    }
    return decoded
  }

  public func set<Value>(_ value: Value, for key: SharedKey<Value>) {
    guard let data = try? JSONEncoder().encode(value) else { return }
    storage(for: key).setData(data, forKey: key.name)
  }

  public func reset<Value>(_ key: SharedKey<Value>) {
    storage(for: key).removeValue(forKey: key.name)
  }

  private func storage<Value>(for key: SharedKey<Value>) -> any KeyValueStorage {
    switch key.storage {
    case .userDefaults: defaults
    case .keychain: keychain
    }
  }
}

/// The foundation keys the scaffold defines. Feature keys join this list with their phase; every
/// key carries an explicit default.
public enum SharedKeys {
  public static let returnKeySends = SharedKey<Bool>(
    name: "return-key-sends",
    defaultValue: false,
    storage: .userDefaults
  )

  public static let sidebarShown = SharedKey<Bool>(
    name: "sidebar-shown",
    defaultValue: true,
    storage: .userDefaults
  )

  public static let lastViewedSession = SharedKey<String?>(
    name: "last-viewed-session",
    defaultValue: nil,
    storage: .userDefaults
  )

  public static let pairedServers = SharedKey<Data?>(
    name: "paired-servers",
    defaultValue: nil,
    storage: .keychain
  )

  /// Every key above, so a test can prove the registry and the defaults stay in step.
  public static let names: [String] = [
    returnKeySends.name,
    sidebarShown.name,
    lastViewedSession.name,
    pairedServers.name,
  ]
}
