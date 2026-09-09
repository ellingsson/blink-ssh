import XCTest
@testable import SwiftTerm

final class MouseWheelProtocolTests: XCTestCase {
  private final class Capture: TerminalDelegate {
    var sent: [[UInt8]] = []

    func send(source: Terminal, data: ArraySlice<UInt8>) {
      sent.append(Array(data))
    }
  }

  func testTmuxMouseModeEncodesSGRWheelUp() {
    let capture = Capture()
    let terminal = Terminal(delegate: capture)
    terminal.feed(buffer: Array("\u{1b}[?1002h\u{1b}[?1006h".utf8)[...])

    let flags = terminal.encodeButton(button: 4, release: false, shift: false, meta: false, control: false)
    terminal.sendEvent(buttonFlags: flags, x: 4, y: 7, pixelX: 4, pixelY: 7)

    XCTAssertEqual(capture.sent.last, Array("\u{1b}[<64;5;8M".utf8))
  }
}
