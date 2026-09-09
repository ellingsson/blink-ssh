import Foundation

struct SSHProfile: Codable, Equatable {
  let alias: String
  let hostName: String
  let user: String
  let port: Int
  let keyID: String?
  let proxyJump: String?
  var command: String? = nil

  var interactiveStartupInput: Data? {
    guard let command = command?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else {
      return nil
    }
    return Data((command + "\n").utf8)
  }
}

struct LegacySSHProfile: Codable {
  let alias: String
  let hostName: String
  let user: String
  let port: String
}

enum SSHProfileStoreError: LocalizedError {
  case invalidProfile
  case duplicateAlias

  var errorDescription: String? {
    switch self {
    case .invalidProfile:
      return "An SSH profile needs an alias, host name, and a port from 1 to 65535."
    case .duplicateAlias:
      return "An SSH profile with that alias already exists."
    }
  }
}

final class SSHProfileStore {
  static let defaultURL = FileManager.default.urls(
    for: .applicationSupportDirectory,
    in: .userDomainMask
  )[0]
  .appendingPathComponent("BlinkSSH", isDirectory: true)
  .appendingPathComponent("profiles.json")

  private let fileURL: URL

  init(fileURL: URL) {
    self.fileURL = fileURL
  }

  func load() throws -> [SSHProfile] {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return []
    }
    return try JSONDecoder().decode([SSHProfile].self, from: Data(contentsOf: fileURL))
  }

  func profile(alias: String) throws -> SSHProfile? {
    try load().first { $0.alias == alias }
  }

  func upsert(_ profile: SSHProfile, replacingAlias: String? = nil) throws {
    guard
      !profile.alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !profile.hostName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      (1...65535).contains(profile.port)
    else {
      throw SSHProfileStoreError.invalidProfile
    }

    var profiles = try load()
    if let replacingAlias {
      guard replacingAlias == profile.alias || !profiles.contains(where: { $0.alias == profile.alias }) else {
        throw SSHProfileStoreError.duplicateAlias
      }
      profiles.removeAll { $0.alias == replacingAlias }
    } else if profiles.contains(where: { $0.alias == profile.alias }) {
      throw SSHProfileStoreError.duplicateAlias
    }
    profiles.append(profile)
    profiles.sort { $0.alias.localizedCaseInsensitiveCompare($1.alias) == .orderedAscending }

    let data = try JSONEncoder().encode(profiles)
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try data.write(to: fileURL, options: .atomic)
  }

  func delete(alias: String) throws {
    var profiles = try load()
    profiles.removeAll { $0.alias == alias }
    let data = try JSONEncoder().encode(profiles)
    try data.write(to: fileURL, options: .atomic)
  }

  func migrateLegacyData(_ data: Data?) throws {
    guard
      !FileManager.default.fileExists(atPath: fileURL.path),
      let data,
      let legacyProfiles = try? JSONDecoder().decode([LegacySSHProfile].self, from: data)
    else {
      return
    }

    for legacyProfile in legacyProfiles {
      try upsert(
        SSHProfile(
          alias: legacyProfile.alias,
          hostName: legacyProfile.hostName,
          user: legacyProfile.user,
          port: Int(legacyProfile.port) ?? 22,
          keyID: nil,
          proxyJump: nil
        )
      )
    }
  }
}
