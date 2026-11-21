import Foundation
import Security

/// The Security calls a keychain store makes, separated so failure paths can be tested without a
/// real keychain.
public protocol KeychainOperations: Sendable {
  func read(service: String, account: String) -> StorageRead
  func write(_ data: Data, service: String, account: String) -> StorageWrite
  func delete(service: String, account: String) -> StorageWrite
}

/// Keychain-backed byte storage. The service name is supplied by the caller: it is an
/// application-defined string, not an issued credential, so the app can start with a migration
/// service and settle the production name before real credentials are stored.
public struct KeychainStorage: KeyValueStorage {
  public let service: String
  private let operations: any KeychainOperations

  public init(service: String, operations: any KeychainOperations = SecItemKeychainOperations()) {
    self.service = service
    self.operations = operations
  }

  public func read(_ key: String) -> StorageRead {
    operations.read(service: service, account: key)
  }

  public func write(_ data: Data, for key: String) -> StorageWrite {
    operations.write(data, service: service, account: key)
  }

  public func delete(_ key: String) -> StorageWrite {
    operations.delete(service: service, account: key)
  }
}

/// The live implementation. Status codes are mapped to typed failures instead of being collapsed
/// into "nothing stored".
public struct SecItemKeychainOperations: KeychainOperations {
  public init() {}

  public func read(service: String, account: String) -> StorageRead {
    var query = baseQuery(service: service, account: account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    switch status {
    case errSecSuccess:
      guard let data = result as? Data else { return .failure(.other(status)) }
      return .value(data)
    case errSecItemNotFound:
      return .missing
    default:
      return .failure(Self.classify(status))
    }
  }

  public func write(_ data: Data, service: String, account: String) -> StorageWrite {
    let query = baseQuery(service: service, account: account)
    let attributes: [String: Any] = [kSecValueData as String: data]
    let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

    if updateStatus == errSecSuccess { return .success }
    guard updateStatus == errSecItemNotFound else {
      return .failure(Self.classify(updateStatus))
    }

    var insertion = query
    insertion[kSecValueData as String] = data
    #if os(iOS)
      insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    #endif
    let addStatus = SecItemAdd(insertion as CFDictionary, nil)
    return addStatus == errSecSuccess ? .success : .failure(Self.classify(addStatus))
  }

  public func delete(service: String, account: String) -> StorageWrite {
    let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
    switch status {
    case errSecSuccess, errSecItemNotFound:
      return .success
    default:
      return .failure(Self.classify(status))
    }
  }

  private func baseQuery(service: String, account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }

  /// Maps an OSStatus to a failure a caller can act on. Kept public so the mapping itself is
  /// testable without provoking a real keychain failure.
  public static func classify(_ status: OSStatus) -> StorageFailure {
    switch status {
    case errSecInteractionNotAllowed, errSecNotAvailable:
      .unavailable
    case errSecMissingEntitlement, errSecAuthFailed:
      .denied
    default:
      .other(status)
    }
  }
}
