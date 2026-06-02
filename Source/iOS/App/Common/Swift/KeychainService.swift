import Foundation
import Security

/// Simple Keychain wrapper for storing credentials per source id.
enum KeychainService {
  private static let service = "iCubeRemoteSource"

  /// Stores or updates a password for a given account id.
  static func setPassword(_ password: String, for account: String) -> Bool {
    let data = Data(password.utf8)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account
    ]
    let update: [String: Any] = [kSecValueData as String: data]
    let status: OSStatus
    if exists(account: account) {
      status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
    } else {
      var add = query
      add[kSecValueData as String] = data
      status = SecItemAdd(add as CFDictionary, nil)
    }
    return status == errSecSuccess
  }

  /// Retrieves a password for a given account id.
  static func getPassword(for account: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true
    ]
    var ref: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &ref)
    guard status == errSecSuccess, let data = ref as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  /// Deletes stored password for a given account id.
  static func deletePassword(for account: String) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account
    ]
    SecItemDelete(query as CFDictionary)
  }

  private static func exists(account: String) -> Bool {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: false
    ]
    let status = SecItemCopyMatching(query as CFDictionary, nil)
    return status == errSecSuccess
  }
}
