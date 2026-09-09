import Foundation

@main
enum KnownHostStoreTests {
  static func main() throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let fileURL = temporaryDirectory.appendingPathComponent("known_hosts")
    try "server.example.test ssh-ed25519 AQID\nother.example.test ecdsa-sha2-nistp256 BAUG\n".write(
      to: fileURL,
      atomically: true,
      encoding: .utf8
    )
    let store = KnownHostStore(fileURL: fileURL)

    let knownHost = try store.record(host: "server.example.test")
    precondition(knownHost?.keyType == "ssh-ed25519")
    precondition(knownHost?.fingerprint == "SHA256:A5BYxvLAy0ksUzsKTRTvd8wPeKvMztUofYShogEc+4E")
    let partialMatch = try store.record(host: "server.example")
    precondition(partialMatch == nil, "Host matching must be exact.")

    let deleted = try store.delete(host: "server.example.test")
    precondition(deleted, "Deleting an existing known host must succeed.")
    let deletedHost = try store.record(host: "server.example.test")
    precondition(deletedHost == nil)
    let remainingHost = try store.record(host: "other.example.test")
    precondition(remainingHost?.keyType == "ecdsa-sha2-nistp256")
    let deletedAgain = try store.delete(host: "server.example.test")
    precondition(!deletedAgain, "Deleting an absent known host must not change the file.")

    print("KnownHostStoreTests passed")
  }
}
