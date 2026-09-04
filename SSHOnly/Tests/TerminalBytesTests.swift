import Foundation

@main
enum TerminalBytesTests {
  static func main() {
    let bytes = Data((0...255).map { UInt8($0) })
    let encoded = TerminalBytes.javascriptBase64(bytes)

    precondition(
      TerminalBytes.data(fromJavaScriptBase64: encoded) == bytes,
      "Base64 terminal messages must preserve every byte value."
    )
    precondition(
      TerminalBytes.data(fromJavaScriptBase64: "not base64") == nil,
      "Malformed terminal input must be rejected."
    )
    precondition(TerminalBytes.tmuxShortcut(.create) == Data([0x02, 0x63]))
    precondition(TerminalBytes.tmuxShortcut(.previous) == Data([0x02, 0x70]))
    precondition(TerminalBytes.tmuxShortcut(.next) == Data([0x02, 0x6e]))
    precondition(TerminalBytes.tmuxShortcut(.detach) == Data([0x02, 0x64]))

    print("TerminalBytesTests passed")
  }
}
