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
    precondition(TerminalBytes.shortcut(.escape) == Data([0x1b]))
    precondition(TerminalBytes.shortcut(.tab) == Data([0x09]))
    precondition(TerminalBytes.shortcut(.up) == Data([0x1b, 0x5b, 0x41]))
    precondition(TerminalBytes.shortcut(.down) == Data([0x1b, 0x5b, 0x42]))
    precondition(TerminalBytes.shortcut(.right) == Data([0x1b, 0x5b, 0x43]))
    precondition(TerminalBytes.shortcut(.left) == Data([0x1b, 0x5b, 0x44]))
    precondition(TerminalBytes.shortcut(.tilde) == Data("~".utf8))
    precondition(TerminalBytes.shortcut(.pipe) == Data("|".utf8))
    precondition(TerminalBytes.shortcut(.slash) == Data("/".utf8))
    precondition(TerminalBytes.modifiedInput(Data("c".utf8), control: true, alt: false) == Data([0x03]))
    precondition(TerminalBytes.modifiedInput(Data("B".utf8), control: true, alt: false) == Data([0x02]))
    precondition(TerminalBytes.modifiedInput(Data("c".utf8), control: false, alt: true) == Data([0x1b, 0x63]))
    precondition(TerminalBytes.modifiedInput(Data("c".utf8), control: true, alt: true) == Data([0x1b, 0x03]))
    precondition(
      TerminalBytes.modifiedInput(Data("å".utf8), control: true, alt: false) == Data("å".utf8),
      "Control must not corrupt multibyte input."
    )

    print("TerminalBytesTests passed")
  }
}
