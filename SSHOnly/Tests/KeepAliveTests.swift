import Foundation

@main
enum KeepAliveTests {
  static func main() {
    precondition(SSHKeepAlive.interval == 30, "Foreground SSH keepalive must run every 30 seconds.")
    print("KeepAliveTests passed")
  }
}
