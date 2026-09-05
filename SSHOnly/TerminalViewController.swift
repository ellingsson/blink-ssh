import Combine
import UIKit
import SSH

final class TerminalViewController: UIViewController, UITextFieldDelegate {
  private let profile: SSHProfile
  private let proxyProfile: SSHProfile?
  private let outputView = UITextView()
  private let inputField = UITextField()
  private let rendererView = XTermTerminalView()
  private let terminalControlStrip = UIView()
  private let terminalControlStack = UIStackView()
  private var rendererBottomToControlStrip: NSLayoutConstraint?
  private var rendererBottomToSafeArea: NSLayoutConstraint?
  private var session: DirectSSHSession?
  private var hasStarted = false
  private var runsCommand: Bool { profile.command?.isEmpty == false }
  private var controlModifierActive = false {
    didSet { updateModifierButtons() }
  }
  private var altModifierActive = false {
    didSet { updateModifierButtons() }
  }
  private var controlModifierButton: UIButton?
  private var altModifierButton: UIButton?

  init(profile: SSHProfile) {
    self.profile = profile
    self.proxyProfile = profile.proxyJump.flatMap { try? SSHProfileStore(fileURL: SSHProfileStore.defaultURL).profile(alias: $0) }
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = profile.alias
    view.backgroundColor = .black
    outputView.backgroundColor = .black
    outputView.textColor = .white
    outputView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
    outputView.isEditable = false
    outputView.text = "Terminal ready.\n"
    outputView.translatesAutoresizingMaskIntoConstraints = false
    inputField.backgroundColor = .secondarySystemBackground
    inputField.textColor = .label
    inputField.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
    inputField.placeholder = "Command"
    inputField.autocapitalizationType = .none
    inputField.autocorrectionType = .no
    inputField.returnKeyType = .send
    inputField.delegate = self
    inputField.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(outputView)
    view.addSubview(inputField)
    rendererView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(rendererView)
    terminalControlStrip.translatesAutoresizingMaskIntoConstraints = false
    terminalControlStrip.backgroundColor = UIColor(red: 157 / 255, green: 158 / 255, blue: 160 / 255, alpha: 1)
    terminalControlStrip.layer.cornerRadius = 12
    terminalControlStrip.clipsToBounds = true
    terminalControlStrip.isHidden = true
    terminalControlStack.translatesAutoresizingMaskIntoConstraints = false
    terminalControlStack.axis = .horizontal
    terminalControlStack.distribution = .fillEqually
    terminalControlStack.spacing = 2
    terminalControlStrip.addSubview(terminalControlStack)
    view.addSubview(terminalControlStrip)
    rendererBottomToControlStrip = rendererView.bottomAnchor.constraint(equalTo: terminalControlStrip.topAnchor)
    rendererBottomToSafeArea = rendererView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
    rendererBottomToSafeArea?.isActive = true
    NSLayoutConstraint.activate([
      outputView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8),
      outputView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
      outputView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
      outputView.bottomAnchor.constraint(equalTo: inputField.topAnchor, constant: -8),
      inputField.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8),
      inputField.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
      inputField.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8),
      inputField.heightAnchor.constraint(equalToConstant: 42),
      rendererView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
      rendererView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
      rendererView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      terminalControlStrip.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
      terminalControlStrip.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
      terminalControlStrip.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
      terminalControlStrip.heightAnchor.constraint(equalToConstant: 44),
      terminalControlStack.leadingAnchor.constraint(equalTo: terminalControlStrip.leadingAnchor, constant: 4),
      terminalControlStack.trailingAnchor.constraint(equalTo: terminalControlStrip.trailingAnchor, constant: -4),
      terminalControlStack.topAnchor.constraint(equalTo: terminalControlStrip.topAnchor, constant: 3),
      terminalControlStack.bottomAnchor.constraint(equalTo: terminalControlStrip.bottomAnchor, constant: -3),
    ])
    navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Disconnect", style: .plain, target: self, action: #selector(disconnect))
    if !runsCommand {
      controlModifierButton = terminalButton(title: "⌃", accessibilityLabel: "Control", action: #selector(toggleControlModifier))
      altModifierButton = terminalButton(title: "⌥", accessibilityLabel: "Alt", action: #selector(toggleAltModifier))
      [
        controlModifierButton,
        altModifierButton,
        terminalButton(title: "⇥", accessibilityLabel: "Tab", shortcut: .tab),
        terminalButton(title: "←", accessibilityLabel: "Left arrow", shortcut: .left),
        terminalButton(title: "↑", accessibilityLabel: "Up arrow", shortcut: .up),
        terminalButton(title: "↓", accessibilityLabel: "Down arrow", shortcut: .down),
        terminalButton(title: "→", accessibilityLabel: "Right arrow", shortcut: .right),
        terminalButton(title: "✓", accessibilityLabel: "Dismiss keyboard", action: #selector(dismissKeyboard)),
      ].compactMap { $0 }.forEach(terminalControlStack.addArrangedSubview)
      updateModifierButtons()
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(keyboardWillShow),
        name: UIResponder.keyboardWillShowNotification,
        object: nil
      )
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(keyboardWillHide),
        name: UIResponder.keyboardWillHideNotification,
        object: nil
      )
    } else {
      terminalControlStrip.isHidden = true
    }
    rendererView.onReady = { [weak self] columns, rows in
      guard let self, !self.hasStarted else { return }
      self.hasStarted = true
      self.navigationItem.prompt = "Connecting…"
      self.start(rows: rows, columns: columns)
    }
    rendererView.onInput = { [weak self] data in self?.sendInput(data) }
    rendererView.onResize = { [weak self] columns, rows in self?.session?.resize(rows: rows, columns: columns) }
    rendererView.onError = { [weak self] error in
      self?.activateTextFallback(error)
    }
    rendererView.load()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    navigationController?.setToolbarHidden(true, animated: animated)
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    navigationController?.setToolbarHidden(true, animated: animated)
  }

  @objc private func keyboardWillShow(_ notification: Notification) {
    setTerminalControlsVisible(true, notification: notification)
  }

  @objc private func keyboardWillHide(_ notification: Notification) {
    setTerminalControlsVisible(false, notification: notification)
  }

  private func setTerminalControlsVisible(_ visible: Bool, notification: Notification) {
    guard !runsCommand, rendererView.superview != nil else { return }
    let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval ?? 0.25
    if visible {
      terminalControlStrip.isHidden = false
      rendererBottomToSafeArea?.isActive = false
      rendererBottomToControlStrip?.isActive = true
      UIView.animate(withDuration: duration) { self.view.layoutIfNeeded() }
    } else {
      UIView.animate(withDuration: duration, animations: { self.view.layoutIfNeeded() }) { _ in
        self.rendererBottomToControlStrip?.isActive = false
        self.rendererBottomToSafeArea?.isActive = true
        self.terminalControlStrip.isHidden = true
        self.view.layoutIfNeeded()
      }
    }
  }

  private func activateTextFallback(_ error: String) {
    rendererView.removeFromSuperview()
    terminalControlStrip.isHidden = true
    outputView.text.append("Terminal visible.\n")
    outputView.text.append("Renderer failed: \(error)\n")
    if !hasStarted {
      hasStarted = true
      DispatchQueue.main.async { [weak self] in
        self?.outputView.text.append("Starting SSH session…\n")
        self?.start(rows: 24, columns: 80)
      }
    }
  }

  func textFieldShouldReturn(_ textField: UITextField) -> Bool {
    guard let text = textField.text, !text.isEmpty else { return false }
    session?.send(Data((text + "\n").utf8))
    textField.text = ""
    return true
  }

  @objc private func disconnect() {
    clearModifiers()
    session?.close()
    navigationController?.popViewController(animated: true)
  }

  @objc private func toggleControlModifier() {
    controlModifierActive.toggle()
  }

  @objc private func toggleAltModifier() {
    altModifierActive.toggle()
  }

  @objc private func dismissKeyboard() {
    view.endEditing(true)
  }

  private func terminalButton(title: String, accessibilityLabel: String, action: Selector) -> UIButton {
    let button = UIButton(type: .system)
    button.setTitle(title, for: .normal)
    button.setTitleColor(.label, for: .normal)
    button.titleLabel?.font = .systemFont(ofSize: 20, weight: .medium)
    button.backgroundColor = .clear
    button.accessibilityLabel = accessibilityLabel
    button.addTarget(self, action: action, for: .touchUpInside)
    return button
  }

  private func terminalButton(title: String, accessibilityLabel: String, shortcut: TerminalBytes.Shortcut) -> UIButton {
    let button = terminalButton(title: title, accessibilityLabel: accessibilityLabel, action: #selector(sendShortcut(_:)))
    button.tag = shortcut.rawValue
    return button
  }

  @objc private func sendShortcut(_ sender: UIButton) {
    guard let shortcut = TerminalBytes.Shortcut(rawValue: sender.tag) else { return }
    sendInput(TerminalBytes.shortcut(shortcut))
  }

  private func sendInput(_ data: Data) {
    session?.send(TerminalBytes.modifiedInput(data, control: controlModifierActive, alt: altModifierActive))
    clearModifiers()
  }

  private func clearModifiers() {
    controlModifierActive = false
    altModifierActive = false
  }

  private func updateModifierButtons() {
    controlModifierButton?.setTitleColor(.label, for: .normal)
    controlModifierButton?.accessibilityLabel = controlModifierActive ? "Control active" : "Control"
    altModifierButton?.setTitleColor(.label, for: .normal)
    altModifierButton?.accessibilityLabel = altModifierActive ? "Alt active" : "Alt"
  }

  private func start(rows: Int, columns: Int) {
    let session = DirectSSHSession(
      profile: profile,
      proxyProfile: proxyProfile,
      initialPTY: SSHClient.PTY(rows: Int32(rows), columns: Int32(columns)),
      hostVerification: { [weak self] verification in self?.verifyHost(verification) ?? .just(.negative) },
      receiveOutput: { [weak self] output in self?.append(output) },
      receiveState: { [weak self] state in self?.update(state) }
    )
    self.session = session
    session.start()
  }

  private func verifyHost(_ verification: VerifyHost) -> AnyPublisher<InteractiveResponse, Error> {
    let fingerprint: String
    let title: String
    switch verification {
    case .unknown(let value): title = "Unknown host"; fingerprint = value
    case .notFound(let value): title = "New known_hosts file"; fingerprint = value
    case .changed(let value): title = "Host key changed"; fingerprint = value
    @unknown default:
      return .just(.negative)
    }
    return Future { [weak self] promise in
      DispatchQueue.main.async {
        let alert = UIAlertController(title: title, message: "SHA256 fingerprint:\n\(fingerprint)", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Reject", style: .cancel) { _ in promise(.success(.negative)) })
        alert.addAction(UIAlertAction(title: "Trust", style: .default) { _ in promise(.success(.affirmative)) })
        self?.present(alert, animated: true)
      }
    }.eraseToAnyPublisher()
  }

  private func append(_ output: Data) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      if self.rendererView.superview != nil {
        self.rendererView.write(output)
        return
      }
      outputView.text.append(String(decoding: output, as: UTF8.self))
      outputView.scrollRangeToVisible(NSRange(location: max(outputView.text.count - 1, 0), length: 0))
    }
  }

  private func update(_ state: DirectSSHSession.State) {
    switch state {
    case .connecting: append(Data("Connecting…\n".utf8))
    case .connected: append(Data("Connected.\n".utf8))
    case .closed: append(Data("Disconnected.\n".utf8))
    case .failed(let message): append(Data("SSH connection failed: \(message)\n".utf8))
    }
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    session?.close()
  }
}
