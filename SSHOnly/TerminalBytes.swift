import Foundation

enum TerminalBytes {
  enum Shortcut: Int {
    case escape
    case tab
    case up
    case down
    case right
    case left
    case tilde
    case pipe
    case slash
  }

  static func javascriptBase64(_ data: Data) -> String {
    data.base64EncodedString()
  }

  static func data(fromJavaScriptBase64 value: String) -> Data? {
    Data(base64Encoded: value)
  }

  static func shortcut(_ shortcut: Shortcut) -> Data {
    switch shortcut {
    case .escape: return Data([0x1b])
    case .tab: return Data([0x09])
    case .up: return Data([0x1b, 0x5b, 0x41])
    case .down: return Data([0x1b, 0x5b, 0x42])
    case .right: return Data([0x1b, 0x5b, 0x43])
    case .left: return Data([0x1b, 0x5b, 0x44])
    case .tilde: return Data("~".utf8)
    case .pipe: return Data("|".utf8)
    case .slash: return Data("/".utf8)
    }
  }

  static func modifiedInput(_ data: Data, control: Bool, alt: Bool) -> Data {
    var result = data
    if control, data.count == 1, let byte = data.first {
      switch byte {
      case 0x40...0x5f, 0x61...0x7a:
        result = Data([byte & 0x1f])
      default:
        break
      }
    }
    if alt {
      result.insert(0x1b, at: 0)
    }
    return result
  }
}
