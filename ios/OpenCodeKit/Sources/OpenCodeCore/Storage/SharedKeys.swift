import ComposableArchitecture
import Foundation

/// Application-defined storage identifiers. The Keychain service follows the configured bundle
/// identifier, so the owner-supplied app identity decides where credentials live instead of a
/// migration constant or a historical identifier.
public enum StorageIdentity {
  public static let fallbackBundleIdentifier = "ai.opencode.migration"

  public static var bundleIdentifier: String {
    Bundle.main.bundleIdentifier ?? fallbackBundleIdentifier
  }

  public static var keychainService: String {
    "\(bundleIdentifier).credentials"
  }
}

/// Where a shared value lives. Credentials and paired servers belong in the keychain; preferences
/// belong in user defaults.
public enum SharedStorage: Equatable, Sendable {
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

/// The outcome of reading a shared value. `missing` and `undecodable` are the documented cases
/// where a caller may use the key's default; `failure` is never one of them.
public enum SharedRead<Value: Sendable>: Sendable {
  case value(Value)
  case missing
  case undecodable
  case failure(StorageFailure)
}

/// Reads and writes shared values through the storage the key names. A storage failure is reported
/// as a failure; only a genuinely absent or undecodable value falls back to the default.
public struct SharedStore: Sendable {
  private let defaults: any KeyValueStorage
  private let keychain: any KeyValueStorage

  public init(defaults: any KeyValueStorage, keychain: any KeyValueStorage) {
    self.defaults = defaults
    self.keychain = keychain
  }

  public func read<Value>(_ key: SharedKey<Value>) -> SharedRead<Value> {
    switch storage(for: key).read(key.name) {
    case .missing:
      return .missing
    case .failure(let failure):
      return .failure(failure)
    case .value(let data):
      guard let decoded = try? JSONDecoder().decode(Value.self, from: data) else {
        return .undecodable
      }
      return .value(decoded)
    }
  }

  /// The value, or the key's default when the value is genuinely absent or undecodable. A storage
  /// failure stays a failure, so a locked keychain is never mistaken for an empty one.
  public func result<Value>(_ key: SharedKey<Value>) -> Result<Value, StorageFailure> {
    switch read(key) {
    case .value(let value): .success(value)
    case .missing, .undecodable: .success(key.defaultValue)
    case .failure(let failure): .failure(failure)
    }
  }

  @discardableResult
  public func write<Value>(_ value: Value, for key: SharedKey<Value>) -> StorageWrite {
    guard let data = try? JSONEncoder().encode(value) else {
      return .failure(.encoding)
    }
    return storage(for: key).write(data, for: key.name)
  }

  @discardableResult
  public func delete<Value>(_ key: SharedKey<Value>) -> StorageWrite {
    storage(for: key).delete(key.name)
  }

  private func storage<Value>(for key: SharedKey<Value>) -> any KeyValueStorage {
    switch key.storage {
    case .userDefaults: defaults
    case .keychain: keychain
    }
  }
}

extension SharedStore: DependencyKey {
  /// The app's store: preferences in `UserDefaults`, credentials in the Keychain service derived
  /// from the configured bundle identifier.
  public static var liveValue: SharedStore {
    SharedStore(
      defaults: UserDefaultsStorage(),
      keychain: KeychainStorage(service: StorageIdentity.keychainService)
    )
  }

  /// A fresh pair of in-memory stores per dependency resolution, so tests never share bytes.
  public static var testValue: SharedStore {
    SharedStore(defaults: InMemoryStorage(), keychain: InMemoryStorage())
  }
}

extension DependencyValues {
  public var sharedStore: SharedStore {
    get { self[SharedStore.self] }
    set { self[SharedStore.self] = newValue }
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

  /// Settings › Experimental's In-App Browser switch. Off by default; the audited key is stable.
  public static let experimentalInAppBrowser = SharedKey<Bool>(
    name: "experimental-in-app-browser",
    defaultValue: false,
    storage: .userDefaults
  )

  /// The file viewer's Wrap Lines choice, kept across files and launches.
  public static let fileViewerWrapsLines = SharedKey<Bool>(
    name: "file-viewer-wraps-lines",
    defaultValue: false,
    storage: .userDefaults
  )

  /// The selected appearance: `system`, `light` or `dark`.
  public static let appearanceColorScheme = SharedKey<String>(
    name: "appearance-color-scheme",
    defaultValue: "system",
    storage: .userDefaults
  )

  /// A person who has completed the first-run welcome.
  public static let onboardingCompleted = SharedKey<Bool>(
    name: "onboarding-completed",
    defaultValue: false,
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
    experimentalInAppBrowser.name,
    fileViewerWrapsLines.name,
    appearanceColorScheme.name,
    onboardingCompleted.name,
    lastViewedSession.name,
    pairedServers.name,
  ]
}
