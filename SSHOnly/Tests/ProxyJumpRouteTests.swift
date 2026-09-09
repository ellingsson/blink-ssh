import Foundation

@main
enum ProxyJumpRouteTests {
  static func main() throws {
    let outer = SSHProfile(alias: "outer", hostName: "outer.example.test", user: "outer-user", port: 2201, keyID: "outer-key", proxyJump: nil)
    let inner = SSHProfile(alias: "inner", hostName: "inner.example.test", user: "inner-user", port: 2202, keyID: "inner-key", proxyJump: "outer")
    let destination = SSHProfile(alias: "target", hostName: "target.example.test", user: "target-user", port: 22, keyID: "target-key", proxyJump: "inner")

    let route = try ProxyJumpRoute.resolve(destination: destination, profiles: [outer, inner, destination])
    precondition(route == [
      ProxyJumpHop(user: "inner-user", host: "inner.example.test", port: 2202, keyID: "inner-key"),
      ProxyJumpHop(user: "outer-user", host: "outer.example.test", port: 2201, keyID: "outer-key"),
    ], "A profile ProxyJump must recursively resolve nearest to outermost.")

    let rawRoute = try ProxyJumpRoute.resolve(
      destination: SSHProfile(alias: "raw", hostName: "target.example.test", user: "target-user", port: 22, keyID: "target-key", proxyJump: "jump-user@jump.example.test:2203"),
      profiles: []
    )
    precondition(rawRoute == [ProxyJumpHop(user: "jump-user", host: "jump.example.test", port: 2203, keyID: "target-key")], "Raw ProxyJump syntax must remain supported.")

    let cycleA = SSHProfile(alias: "a", hostName: "a.example.test", user: "user", port: 22, keyID: "a-key", proxyJump: "b")
    let cycleB = SSHProfile(alias: "b", hostName: "b.example.test", user: "user", port: 22, keyID: "b-key", proxyJump: "a")
    do {
      _ = try ProxyJumpRoute.resolve(destination: cycleA, profiles: [cycleA, cycleB])
      preconditionFailure("ProxyJump cycles must be rejected.")
    } catch ProxyJumpRouteError.cycle {
      // Expected.
    }

    print("ProxyJumpRouteTests passed")
  }
}
