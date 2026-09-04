import Combine
import UIKit
import SSH

final class TerminalViewController: UIViewController, UITextFieldDelegate {
  private let profile: SSHProfile
  private let proxyProfile: SSHProfile?
  private let outputView = UITextView()
  private let inputField = UITextField()
  private var session: DirectSSHSession?
  private var hasStarted = false

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
    NSLayoutConstraint.activate([
      outputView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8),
      outputView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
      outputView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
      outputView.bottomAnchor.constraint(equalTo: inputField.topAnchor, constant: -8),
      inputField.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8),
      inputField.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
      inputField.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8),
      inputField.heightAnchor.constraint(equalToConstant: 42),
    ])
    navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Disconnect", style: .plain, target: self, action: #selector(disconnect))
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    outputView.text.append("Terminal visible.\n")
    guard !hasStarted else { return }
    hasStarted = true
    DispatchQueue.main.async { [weak self] in
      self?.outputView.text.append("Starting SSH session…\n")
      self?.start()
    }
  }

  func textFieldShouldReturn(_ textField: UITextField) -> Bool {
    guard let text = textField.text, !text.isEmpty else { return false }
    session?.send(text + "\n")
    textField.text = ""
    return true
  }

  @objc private func disconnect() {
    session?.close()
    navigationController?.popViewController(animated: true)
  }

  private func start() {
    let session = DirectSSHSession(
      profile: profile,
      proxyProfile: proxyProfile,
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

  private func append(_ output: String) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      outputView.text.append(output)
      outputView.scrollRangeToVisible(NSRange(location: max(outputView.text.count - 1, 0), length: 0))
    }
  }

  private func update(_ state: DirectSSHSession.State) {
    switch state {
    case .connecting: append("Connecting…\n")
    case .connected: append("Connected.\n")
    case .closed: append("Disconnected.\n")
    case .failed(let message): append("SSH connection failed: \(message)\n")
    }
  }

  deinit { session?.close() }
}
