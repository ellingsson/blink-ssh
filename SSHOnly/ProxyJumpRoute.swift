import Foundation

struct ProxyJumpHop: Equatable {
  let user: String
  let host: String
  let port: Int
  let keyID: String?
}

enum ProxyJumpRouteError: LocalizedError, Equatable {
  case invalidJump
  case cycle

  var errorDescription: String? {
    switch self {
    case .invalidJump: return "ProxyJump supports one [user@]host[:port] hop."
    case .cycle: return "ProxyJump profiles must not form a cycle."
    }
  }
}

enum ProxyJumpRoute {
  static func resolve(destination: SSHProfile, profiles: [SSHProfile]) throws -> [ProxyJumpHop] {
    var route: [ProxyJumpHop] = []
    var current = destination
    var visitedAliases: Set<String> = [destination.alias]
    let profilesByAlias = Dictionary(uniqueKeysWithValues: profiles.map { ($0.alias, $0) })

    while let value = current.proxyJump?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
      if let profile = profilesByAlias[value] {
        guard visitedAliases.insert(profile.alias).inserted else { throw ProxyJumpRouteError.cycle }
        route.append(ProxyJumpHop(user: profile.user, host: profile.hostName, port: profile.port, keyID: profile.keyID))
        current = profile
      } else {
        route.append(try parse(value, defaultUser: current.user, keyID: current.keyID))
        break
      }
    }
    return route
  }

  private static func parse(_ value: String, defaultUser: String, keyID: String?) throws -> ProxyJumpHop {
    guard !value.contains(","), !value.contains(" ") else { throw ProxyJumpRouteError.invalidJump }
    let userAndHost = value.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
    let user: String
    let hostPort: Substring
    if userAndHost.count == 2 {
      guard !userAndHost[0].isEmpty else { throw ProxyJumpRouteError.invalidJump }
      user = String(userAndHost[0])
      hostPort = userAndHost[1]
    } else {
      user = defaultUser
      hostPort = userAndHost[0]
    }
    let parts = hostPort.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    guard !user.isEmpty, !parts[0].isEmpty else { throw ProxyJumpRouteError.invalidJump }
    let port: Int
    if parts.count == 2 {
      guard let parsed = Int(parts[1]), (1...65535).contains(parsed) else { throw ProxyJumpRouteError.invalidJump }
      port = parsed
    } else {
      port = 22
    }
    return ProxyJumpHop(user: user, host: String(parts[0]), port: port, keyID: keyID)
  }
}
