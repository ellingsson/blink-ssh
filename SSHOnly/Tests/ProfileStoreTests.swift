import Foundation

@main
enum ProfileStoreTests {
  static func main() throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let fileURL = temporaryDirectory.appendingPathComponent("profiles.json")
    let store = SSHProfileStore(fileURL: fileURL)
    let profile = SSHProfile(alias: "test", hostName: "example.test", user: "me", port: 22, keyID: nil, proxyJump: nil)

    try store.upsert(profile)
    let reloaded = try SSHProfileStore(fileURL: fileURL).load()

    precondition(reloaded == [profile], "Profile store must persist an SSH profile without key material.")

    let selectedKeyProfile = SSHProfile(alias: "test", hostName: "example.test", user: "me", port: 22, keyID: "phone", proxyJump: "jump.example.test")
    try store.upsert(selectedKeyProfile)
    let keySelectedProfiles = try store.load()
    precondition(keySelectedProfiles == [selectedKeyProfile], "Saving a profile must persist its selected key ID.")
    let resolvedProxyProfile = try store.profile(alias: "test")
    precondition(resolvedProxyProfile == selectedKeyProfile, "A ProxyJump alias must resolve to its saved SSH profile.")
    try store.delete(alias: "test")
    let deletedProfiles = try store.load()
    precondition(deletedProfiles.isEmpty, "Deleting a profile must remove the saved profile.")

    let legacyURL = temporaryDirectory.appendingPathComponent("legacy-profiles.json")
    let legacyStore = SSHProfileStore(fileURL: legacyURL)
    let legacyData = try JSONEncoder().encode([
      LegacySSHProfile(alias: "legacy", hostName: "legacy.example.test", user: "me", port: "")
    ])
    try legacyStore.migrateLegacyData(legacyData)
    let migratedProfiles = try legacyStore.load()
    precondition(
      migratedProfiles == [SSHProfile(alias: "legacy", hostName: "legacy.example.test", user: "me", port: 22, keyID: nil, proxyJump: nil)],
      "Legacy profiles must migrate without losing host details."
    )

    let previousFormatURL = temporaryDirectory.appendingPathComponent("previous-format.json")
    try "[{\"alias\":\"old\",\"hostName\":\"old.example.test\",\"user\":\"me\",\"port\":22,\"keyID\":null}]".data(using: .utf8)!.write(to: previousFormatURL)
    let previousFormatProfiles = try SSHProfileStore(fileURL: previousFormatURL).load()
    precondition(
      previousFormatProfiles == [SSHProfile(alias: "old", hostName: "old.example.test", user: "me", port: 22, keyID: nil, proxyJump: nil)],
      "Profiles saved before ProxyJump support must remain readable."
    )
    print("ProfileStoreTests passed")
  }
}
