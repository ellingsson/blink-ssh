import CryptoKit
import Foundation

struct KnownHostRecord: Equatable {
  let host: String
  let keyType: String
  let fingerprint: String
}

enum KnownHostStoreError: LocalizedError {
  case invalidKey

  var errorDescription: String? {
    switch self {
    case .invalidKey:
      return "The saved server key is invalid."
    }
  }
}

final class KnownHostStore {
  static let defaultURL = FileManager.default.urls(
    for: .applicationSupportDirectory,
    in: .userDomainMask
  )[0]
  .appendingPathComponent("BlinkSSH/ssh", isDirectory: true)
  .appendingPathComponent("known_hosts")

  private let fileURL: URL

  init(fileURL: URL) {
    self.fileURL = fileURL
  }

  func record(host: String) throws -> KnownHostRecord? {
    for line in try lines() {
      guard let entry = entry(from: line), entry.host == host else { continue }
      guard let keyData = Data(base64Encoded: entry.publicKey) else {
        throw KnownHostStoreError.invalidKey
      }
      let digest = SHA256.hash(data: keyData)
      let fingerprint = "SHA256:" + Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
      return KnownHostRecord(host: entry.host, keyType: entry.keyType, fingerprint: fingerprint)
    }
    return nil
  }

  func delete(host: String) throws -> Bool {
    let existingLines = try lines()
    let remainingLines = existingLines.filter { entry(from: $0)?.host != host }
    guard remainingLines.count != existingLines.count else { return false }
    try remainingLines.joined(separator: "\n").appending("\n").write(to: fileURL, atomically: true, encoding: .utf8)
    return true
  }

  static func ensureDefaultDirectory() throws -> String {
    let directoryURL = defaultURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    return directoryURL.path
  }

  private func lines() throws -> [String] {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
    return try String(contentsOf: fileURL, encoding: .utf8).components(separatedBy: .newlines)
  }

  private func entry(from line: String) -> (host: String, keyType: String, publicKey: String)? {
    guard !line.hasPrefix("#") else { return nil }
    let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
    guard fields.count >= 3 else { return nil }
    return (String(fields[0]), String(fields[1]), String(fields[2]))
  }
}
