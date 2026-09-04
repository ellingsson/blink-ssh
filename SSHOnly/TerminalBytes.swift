import Foundation

enum TerminalBytes {
  enum TmuxShortcut {
    case create
    case previous
    case next
    case detach
  }

  static func javascriptBase64(_ data: Data) -> String {
    data.base64EncodedString()
  }

  static func data(fromJavaScriptBase64 value: String) -> Data? {
    Data(base64Encoded: value)
  }

  static func tmuxShortcut(_ shortcut: TmuxShortcut) -> Data {
    let command: UInt8
    switch shortcut {
    case .create: command = 0x63
    case .previous: command = 0x70
    case .next: command = 0x6e
    case .detach: command = 0x64
    }
    return Data([0x02, command])
  }
}
