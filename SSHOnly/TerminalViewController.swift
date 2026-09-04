import Combine
import UIKit
import SSH

final class TerminalViewController: UIViewController, UITextFieldDelegate {
  private let profile: SSHProfile
  private let proxyProfile: SSHProfile?
  private let outputView = UITextView()
  private let inputField = UITextField()
  private let rendererView = XTermTerminalView()
  private var session: DirectSSHSession?
  private var hasStarted = false
  private var runsCommand: Bool { profile.command?.isEmpty == false }

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
      rendererView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
    ])
    navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Disconnect", style: .plain, target: self, action: #selector(disconnect))
    if !runsCommand {
      toolbarItems = [
        tmuxButton(title: "C", accessibilityLabel: "tmux create window", action: #selector(createTmuxWindow)),
        tmuxButton(title: "P", accessibilityLabel: "tmux previous window", action: #selector(previousTmuxWindow)),
        tmuxButton(title: "N", accessibilityLabel: "tmux next window", action: #selector(nextTmuxWindow)),
        tmuxButton(title: "D", accessibilityLabel: "tmux detach", action: #selector(detachTmux)),
      ]
    }
    rendererView.onReady = { [weak self] columns, rows in
      guard let self, !self.hasStarted else { return }
      self.hasStarted = true
      self.navigationItem.prompt = "Connecting…"
      self.start(rows: rows, columns: columns)
    }
    rendererView.onInput = { [weak self] data in self?.session?.send(data) }
    rendererView.onResize = { [weak self] columns, rows in self?.session?.resize(rows: rows, columns: columns) }
    rendererView.onError = { [weak self] error in
      self?.activateTextFallback(error)
    }
    rendererView.load()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    navigationController?.setToolbarHidden(runsCommand, animated: animated)
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    navigationController?.setToolbarHidden(true, animated: animated)
  }

  private func activateTextFallback(_ error: String) {
    rendererView.removeFromSuperview()
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
    session?.close()
    navigationController?.popViewController(animated: true)
  }

  @objc private func createTmuxWindow() { sendTmuxShortcut(.create) }
  @objc private func previousTmuxWindow() { sendTmuxShortcut(.previous) }
  @objc private func nextTmuxWindow() { sendTmuxShortcut(.next) }
  @objc private func detachTmux() { sendTmuxShortcut(.detach) }

  private func tmuxButton(title: String, accessibilityLabel: String, action: Selector) -> UIBarButtonItem {
    let button = UIBarButtonItem(title: title, style: .plain, target: self, action: action)
    button.accessibilityLabel = accessibilityLabel
    return button
  }

  private func sendTmuxShortcut(_ shortcut: TerminalBytes.TmuxShortcut) {
    session?.send(TerminalBytes.tmuxShortcut(shortcut))
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

  deinit { session?.close() }
}
