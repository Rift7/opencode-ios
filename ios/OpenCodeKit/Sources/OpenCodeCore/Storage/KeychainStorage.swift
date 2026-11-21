import Foundation
import Security

/// Keychain-backed byte storage. The service name is supplied by the caller: it is an
/// application-defined string, not an issued credential, so the app can start with a migration
/// service and settle the production name before real credentials are stored.
public struct KeychainStorage: KeyValueStorage {
  public let service: String

  public init(service: String) {
    self.service = service
  }

  public func data(forKey key: String) -> Data? {
    var query = baseQuery(for: key)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess else { return nil }
    return result as? Data
  }

  public func setData(_ data: Data?, forKey key: String) {
    guard let data else {
      removeValue(forKey: key)
      return
    }

    let query = baseQuery(for: key)
    let attributes: [String: Any] = [kSecValueData as String: data]
    let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    guard updateStatus == errSecItemNotFound else { return }

    var insertion = query
    insertion[kSecValueData as String] = data
    #if os(iOS)
      insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    #endif
    _ = SecItemAdd(insertion as CFDictionary, nil)
  }

  public func removeValue(forKey key: String) {
    _ = SecItemDelete(baseQuery(for: key) as CFDictionary)
  }

  private func baseQuery(for key: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
    ]
  }
}
