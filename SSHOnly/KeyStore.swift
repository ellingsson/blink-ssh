import Foundation
import Security
import SSH

struct SSHKeyRecord: Codable, Equatable {
  let id: String
  let publicKey: String
  let type: String
}

enum SSHKeyStoreError: LocalizedError {
  case invalidID
  case duplicateID
  case keychain(OSStatus)
  case invalidKeyData
  case debugTestIdentityMissing

  var errorDescription: String? {
    switch self {
    case .invalidID:
      return "A key needs a name."
    case .duplicateID:
      return "A key with that name already exists."
    case .keychain(let status):
      return SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)."
    case .invalidKeyData:
      return "The Keychain key data is invalid."
    case .debugTestIdentityMissing:
      return "The Debug test identity is unavailable."
    }
  }
}

final class SSHKeyStore {
  private let metadataKey = "ssh-only.key-records"
  private let service = "com.example.blinkssh.ssh-key"
#if DEBUG
  private static let debugTestIdentityID = "Debug Test Identity"
#endif

  func records() -> [SSHKeyRecord] {
    var records: [SSHKeyRecord]
    if let data = UserDefaults.standard.data(forKey: metadataKey) {
      records = (try? JSONDecoder().decode([SSHKeyRecord].self, from: data)) ?? []
    } else {
      records = []
    }
#if DEBUG
    if let debugRecord = try? debugTestIdentityRecord() {
      records.append(debugRecord)
    }
#endif
    return records.sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
  }

  func createKey(id: String, comment: String) throws -> SSHKeyRecord {
    let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !id.isEmpty else {
      throw SSHKeyStoreError.invalidID
    }
    guard !records().contains(where: { $0.id == id }) else {
      throw SSHKeyStoreError.duplicateID
    }

    let key = try SSHKey(type: .ed25519, bits: 0)
    let record = SSHKeyRecord(
      id: id,
      publicKey: try key.authorizedKey(withComment: comment),
      type: key.sshKeyType.shortName
    )
    try storePrivateKey(try key.privateKeyFileBlob(), for: id)

    var records = records()
    records.append(record)
    records.sort { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    UserDefaults.standard.set(try JSONEncoder().encode(records), forKey: metadataKey)
    return record
  }

  func privateKey(for id: String) throws -> String {
#if DEBUG
    if id == Self.debugTestIdentityID {
      return try String(contentsOf: debugTestIdentityURL(), encoding: .utf8)
    }
#endif
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: id,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
      if status == errSecSuccess { throw SSHKeyStoreError.invalidKeyData }
      throw SSHKeyStoreError.keychain(status)
    }
    return key
  }

  func deleteKey(id: String) throws {
#if DEBUG
    if id == Self.debugTestIdentityID {
      return
    }
#endif
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: id,
    ]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw SSHKeyStoreError.keychain(status)
    }
    let updated = records().filter { $0.id != id }
    UserDefaults.standard.set(try JSONEncoder().encode(updated), forKey: metadataKey)
  }

  private func storePrivateKey(_ data: Data, for id: String) throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: id,
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw SSHKeyStoreError.keychain(status)
    }
  }

#if DEBUG
  private func debugTestIdentityRecord() throws -> SSHKeyRecord {
    let key = try SSHKey(fromFileBlob: Data(contentsOf: debugTestIdentityURL()))
    return SSHKeyRecord(
      id: Self.debugTestIdentityID,
      publicKey: try key.authorizedKey(withComment: "Debug Test Identity"),
      type: key.sshKeyType.shortName
    )
  }

  private func debugTestIdentityURL() throws -> URL {
    guard let url = Bundle.main.url(forResource: "TestIdentity", withExtension: nil) else {
      throw SSHKeyStoreError.debugTestIdentityMissing
    }
    return url
  }
#endif
}
