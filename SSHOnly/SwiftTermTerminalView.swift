import Foundation
import SwiftTerm
import UIKit

final class TerminalZoomViewport: UIView {
  private weak var contentView: UIView?
  private var scale: CGFloat = 1
  private var previousPinchScale: CGFloat = 1
  private var previousPinchLocation = CGPoint.zero
  private var offset = CGPoint.zero
  private var startingOffset = CGPoint.zero

  override init(frame: CGRect) {
    super.init(frame: frame)
    clipsToBounds = true
    addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:))))
    let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    pan.minimumNumberOfTouches = 2
    addGestureRecognizer(pan)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func embed(_ view: UIView) {
    contentView = view
    view.translatesAutoresizingMaskIntoConstraints = false
    addSubview(view)
    NSLayoutConstraint.activate([
      view.leadingAnchor.constraint(equalTo: leadingAnchor),
      view.trailingAnchor.constraint(equalTo: trailingAnchor),
      view.topAnchor.constraint(equalTo: topAnchor),
      view.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    applyZoom()
  }

  @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
    switch gesture.state {
    case .began:
      previousPinchScale = scale
      previousPinchLocation = gesture.location(in: self)
    case .changed, .ended:
      let location = gesture.location(in: self)
      let center = CGPoint(x: bounds.midX, y: bounds.midY)
      let contentPoint = CGPoint(
        x: (previousPinchLocation.x - center.x - offset.x) / previousPinchScale,
        y: (previousPinchLocation.y - center.y - offset.y) / previousPinchScale
      )
      scale = min(max(previousPinchScale * gesture.scale, 1), 3)
      offset = CGPoint(
        x: location.x - center.x - scale * contentPoint.x,
        y: location.y - center.y - scale * contentPoint.y
      )
      clampOffset()
      applyZoom()
      previousPinchScale = scale
      previousPinchLocation = location
      gesture.scale = 1
    default:
      break
    }
  }

  @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
    guard scale > 1 else { return }
    switch gesture.state {
    case .began:
      startingOffset = offset
    case .changed, .ended:
      let translation = gesture.translation(in: self)
      offset = CGPoint(x: startingOffset.x + translation.x, y: startingOffset.y + translation.y)
      clampOffset()
      applyZoom()
    default:
      break
    }
  }

  private func clampOffset() {
    let maximumX = bounds.width * (scale - 1) / 2
    let maximumY = bounds.height * (scale - 1) / 2
    offset.x = min(max(offset.x, -maximumX), maximumX)
    offset.y = min(max(offset.y, -maximumY), maximumY)
  }

  private func applyZoom() {
    guard let contentView else { return }
    contentView.transform = .identity
    contentView.center = CGPoint(x: bounds.midX + offset.x, y: bounds.midY + offset.y)
    contentView.transform = CGAffineTransform(scaleX: scale, y: scale)
  }
}

final class SwiftTermTerminalView: TerminalView, TerminalViewDelegate {
  var onReady: ((Int, Int) -> Void)?
  var onInput: ((Data) -> Void)?
  var onResize: ((Int, Int) -> Void)?
  var onError: ((String) -> Void)?

  private var hasAnnouncedSize = false

  convenience init() {
    self.init(frame: .zero)
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    terminalDelegate = self
    inputAccessoryView = nil
    backgroundColor = .black
    nativeBackgroundColor = .black
    nativeForegroundColor = .white
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    terminalDelegate = self
    inputAccessoryView = nil
    backgroundColor = .black
    nativeBackgroundColor = .black
    nativeForegroundColor = .white
  }

  func load() {
    DispatchQueue.main.async { [weak self] in
      self?.reportCurrentSize()
    }
  }

  func write(_ data: Data) {
    feed(byteArray: ArraySlice(data))
  }

  func toggleDirectSelectionMode() {
    setDirectSelectionMode(!isDirectSelectionMode)
  }

  var isDirectSelectionMode: Bool {
    !allowMouseReporting
  }

  func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
    if hasAnnouncedSize {
      onResize?(newCols, newRows)
    } else {
      hasAnnouncedSize = true
      onReady?(newCols, newRows)
    }
  }

  func setTerminalTitle(source: TerminalView, title: String) { }

  func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) { }

  func send(source: TerminalView, data: ArraySlice<UInt8>) {
    onInput?(Data(data))
  }

  func scrolled(source: TerminalView, position: Double) { }

  func requestOpenLink(source: TerminalView, link: String, params: [String: String]) { }

  func clipboardCopy(source: TerminalView, content: Data) {
    UIPasteboard.general.setData(content, forPasteboardType: "public.utf8-plain-text")
  }

  func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) { }

  func rangeChanged(source: TerminalView, startY: Int, endY: Int) { }

  private func reportCurrentSize() {
    let dimensions = getTerminal().getDims()
    sizeChanged(source: self, newCols: dimensions.cols, newRows: dimensions.rows)
  }
}
