import Foundation
import UIKit
import WebKit

private final class XTermWebView: WKWebView {
  override var inputAccessoryView: UIView? { nil }
}

final class XTermTerminalView: UIView, WKScriptMessageHandler, WKNavigationDelegate {
  var onReady: ((Int, Int) -> Void)?
  var onInput: ((Data) -> Void)?
  var onResize: ((Int, Int) -> Void)?
  var onError: ((String) -> Void)?

  private let contentController = WKUserContentController()
  private lazy var webView: WKWebView = {
    let configuration = WKWebViewConfiguration()
    configuration.userContentController = contentController
    let view = XTermWebView(frame: .zero, configuration: configuration)
    view.navigationDelegate = self
    view.isOpaque = false
    view.backgroundColor = .black
    view.scrollView.bounces = false
    view.scrollView.showsHorizontalScrollIndicator = false
    view.scrollView.showsVerticalScrollIndicator = false
    view.inputAssistantItem.leadingBarButtonGroups = []
    view.inputAssistantItem.trailingBarButtonGroups = []
    return view
  }()

  override init(frame: CGRect) {
    super.init(frame: frame)
    contentController.add(self, name: "xterm")
    backgroundColor = .black
    addSubview(webView)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    webView.frame = bounds
  }

  deinit {
    contentController.removeScriptMessageHandler(forName: "xterm")
  }

  func load() {
    guard let url = Bundle.main.url(forResource: "XTerminal", withExtension: "html") else {
      onError?("Missing xterm renderer resource")
      return
    }
    webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
  }

  func write(_ data: Data) {
    guard let base64 = data.base64EncodedString().jsonStringLiteral else { return }
    webView.evaluateJavaScript("XTerminal.writeBase64(\(base64));") { [weak self] _, error in
      guard let error else { return }
      self?.onError?("Write failed: \(error.localizedDescription)")
    }
  }

  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    guard message.name == "xterm", let body = message.body as? [String: Any], let type = body["type"] as? String else {
      return
    }
    switch type {
    case "ready", "resize":
      guard let columns = body["columns"] as? Int, let rows = body["rows"] as? Int else { return }
      if type == "ready" {
        onReady?(columns, rows)
      } else {
        onResize?(columns, rows)
      }
    case "input":
      guard let base64 = body["base64"] as? String, let data = Data(base64Encoded: base64) else { return }
      onInput?(data)
    case "error":
      let stage = body["stage"] as? String ?? "unknown"
      let detail = body["message"] as? String ?? "Unknown error"
      onError?("\(stage): \(detail)")
    default:
      return
    }
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    onError?("Navigation failed: \(error.localizedDescription)")
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    onError?("Navigation failed: \(error.localizedDescription)")
  }
}

private extension String {
  var jsonStringLiteral: String? {
    guard let data = try? JSONEncoder().encode(self) else { return nil }
    return String(data: data, encoding: .utf8)
  }
}
