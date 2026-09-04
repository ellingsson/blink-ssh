// SPDX-License-Identifier: GPL-3.0-or-later

import UIKit
import BlinkConfig
import SSH

@main
final class SSHOnlyAppDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let window = UIWindow(frame: UIScreen.main.bounds)
    window.rootViewController = UINavigationController(rootViewController: SSHOnlyRootViewController())
    window.makeKeyAndVisible()
    self.window = window
    return true
  }
}

private final class SSHOnlyRootViewController: UITableViewController {
  private let legacyProfilesKey = "ssh-only.profiles"
  private let store = SSHProfileStore(fileURL: SSHProfileStore.defaultURL)
  private var profiles: [SSHProfile] = []


  override func viewDidLoad() {
    super.viewDidLoad()
    title = "SSH Profiles"
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      barButtonSystemItem: .add,
      target: self,
      action: #selector(addProfile)
    )
    navigationItem.leftBarButtonItem = UIBarButtonItem(
      title: "Keys",
      style: .plain,
      target: self,
      action: #selector(showKeys)
    )
    refreshControl = UIRefreshControl()
    refreshControl?.addTarget(self, action: #selector(reloadProfiles), for: .valueChanged)
    reloadProfiles()
  }

  @objc private func reloadProfiles() {
    try? store.migrateLegacyData(UserDefaults.standard.data(forKey: legacyProfilesKey))
    profiles = (try? store.load()) ?? []
    tableView.reloadData()
    refreshControl?.endRefreshing()
  }

  @objc private func addProfile() {
    showEditor(for: nil)
  }

  @objc private func showKeys() {
    navigationController?.pushViewController(SSHKeysViewController(), animated: true)
  }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    profiles.count
  }

  override func tableView(
    _ tableView: UITableView,
    cellForRowAt indexPath: IndexPath
  ) -> UITableViewCell {
    let profile = profiles[indexPath.row]
    let cell = tableView.dequeueReusableCell(withIdentifier: "profile")
      ?? UITableViewCell(style: .subtitle, reuseIdentifier: "profile")
    cell.textLabel?.text = profile.alias
    let destination = "\(profile.user.isEmpty ? "" : "\(profile.user)@")\(profile.hostName):\(profile.port)"
    cell.detailTextLabel?.text = profile.keyID.map { "\(destination) · \($0)" } ?? destination
    cell.accessoryType = .disclosureIndicator
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    showEditor(for: profiles[indexPath.row])
  }

  override func tableView(
    _ tableView: UITableView,
    commit editingStyle: UITableViewCell.EditingStyle,
    forRowAt indexPath: IndexPath
  ) {
    guard editingStyle == .delete else { return }
    do {
      try store.delete(alias: profiles[indexPath.row].alias)
      reloadProfiles()
    } catch {
      let alert = UIAlertController(title: "SSH profile", message: error.localizedDescription, preferredStyle: .alert)
      alert.addAction(UIAlertAction(title: "OK", style: .default))
      present(alert, animated: true)
    }
  }

  private func showEditor(for profile: SSHProfile?) {
    let editor = SSHProfileEditorViewController(profile: profile) { [weak self] updated in
      guard let self else { return }
      try self.store.upsert(updated, replacingAlias: profile?.alias)
      self.reloadProfiles()
    }
    navigationController?.pushViewController(editor, animated: true)
  }
}

private final class SSHProfileEditorViewController: UITableViewController {
  private let existingProfile: SSHProfile?
  private let onSave: (SSHProfile) throws -> Void
  private var selectedKeyID: String?
  private let aliasField = UITextField()
  private let hostField = UITextField()
  private let userField = UITextField()
  private let portField = UITextField()
  private let proxyJumpField = UITextField()
  private let commandField = UITextField()

  init(profile: SSHProfile?, onSave: @escaping (SSHProfile) throws -> Void) {
    existingProfile = profile
    self.onSave = onSave
    selectedKeyID = profile?.keyID
    super.init(style: .insetGrouped)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = existingProfile == nil ? "New SSH Profile" : "Edit SSH Profile"
    navigationItem.rightBarButtonItems = [
      UIBarButtonItem(title: "Connect", style: .done, target: self, action: #selector(connect)),
      UIBarButtonItem(barButtonSystemItem: .save, target: self, action: #selector(save)),
    ]
    configure(aliasField, placeholder: "Alias", value: existingProfile?.alias)
    configure(hostField, placeholder: "Host name or address", value: existingProfile?.hostName)
    configure(userField, placeholder: "User (optional)", value: existingProfile?.user)
    configure(portField, placeholder: "Port", value: existingProfile.map { String($0.port) })
    configure(proxyJumpField, placeholder: "ProxyJump (optional)", value: existingProfile?.proxyJump)
    configure(commandField, placeholder: "Command (optional)", value: existingProfile?.command)
    hostField.keyboardType = .URL
    portField.keyboardType = .numberPad
  }

  private func configure(_ field: UITextField, placeholder: String, value: String?) {
    field.placeholder = placeholder
    field.text = value
    field.autocapitalizationType = .none
    field.autocorrectionType = .no
    field.translatesAutoresizingMaskIntoConstraints = false
  }

  @objc private func save() {
    let profile = makeProfile()
    do {
      try onSave(profile)
      navigationController?.popViewController(animated: true)
    } catch {
      presentSaveError(error)
    }
  }

  @objc private func connect() {
    let profile = makeProfile()
    do {
      try onSave(profile)
      navigationController?.pushViewController(TerminalViewController(profile: profile), animated: true)
    } catch {
      presentSaveError(error)
    }
  }

  private func makeProfile() -> SSHProfile {
    let proxyJump = proxyJumpField.text?.trimmingCharacters(in: .whitespacesAndNewlines)
    let command = commandField.text?.trimmingCharacters(in: .whitespacesAndNewlines)
    return SSHProfile(
      alias: aliasField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
      hostName: hostField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
      user: userField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
      port: Int(portField.text ?? "") ?? 22,
      keyID: selectedKeyID,
      proxyJump: proxyJump?.isEmpty == false ? proxyJump : nil,
      command: command?.isEmpty == false ? command : nil
    )
  }

  private func presentSaveError(_ error: Error) {
    let alert = UIAlertController(title: "SSH profile", message: error.localizedDescription, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    present(alert, animated: true)
  }

  override func numberOfSections(in tableView: UITableView) -> Int { 2 }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    section == 0 ? 6 : 1
  }

  override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    section == 0 ? "Connection" : "Authentication"
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    if indexPath.section == 1 {
      let cell = tableView.dequeueReusableCell(withIdentifier: "key")
        ?? UITableViewCell(style: .value1, reuseIdentifier: "key")
      cell.textLabel?.text = "SSH key"
      cell.detailTextLabel?.text = selectedKeyID ?? "None"
      cell.accessoryType = .disclosureIndicator
      return cell
    }

    let fields = [aliasField, hostField, userField, portField, proxyJumpField, commandField]
    let cell = tableView.dequeueReusableCell(withIdentifier: "field-\(indexPath.row)")
      ?? UITableViewCell(style: .default, reuseIdentifier: "field-\(indexPath.row)")
    let field = fields[indexPath.row]
    if field.superview == nil {
      cell.contentView.addSubview(field)
      NSLayoutConstraint.activate([
        field.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
        field.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
        field.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 4),
        field.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -4),
      ])
    }
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    guard indexPath.section == 1 else { return }
    tableView.deselectRow(at: indexPath, animated: true)
    let alert = UIAlertController(title: "SSH key", message: nil, preferredStyle: .actionSheet)
    alert.addAction(UIAlertAction(title: "None", style: .default) { [weak self] _ in
      self?.selectedKeyID = nil
      self?.tableView.reloadSections(IndexSet(integer: 1), with: .automatic)
    })
    for record in SSHKeyStore().records() {
      alert.addAction(UIAlertAction(title: record.id, style: .default) { [weak self] _ in
        self?.selectedKeyID = record.id
        self?.tableView.reloadSections(IndexSet(integer: 1), with: .automatic)
      })
    }
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    present(alert, animated: true)
  }
}

private final class SSHKeysViewController: UITableViewController {
  private let store = SSHKeyStore()
  private var records: [SSHKeyRecord] = []

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "SSH Keys"
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      barButtonSystemItem: .add,
      target: self,
      action: #selector(addKey)
    )
    reloadKeys()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    reloadKeys()
  }

  @objc private func addKey() {
    let alert = UIAlertController(
      title: "New SSH key",
      message: "Creates an Ed25519 key. Its private part remains in this device's Keychain.",
      preferredStyle: .alert
    )
    alert.addTextField { field in
      field.placeholder = "Key name"
      field.autocapitalizationType = .none
    }
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(UIAlertAction(title: "Create", style: .default) { [weak self, weak alert] _ in
      guard let self, let id = alert?.textFields?.first?.text else { return }
      do {
        _ = try self.store.createKey(id: id, comment: id)
        self.reloadKeys()
      } catch {
        self.presentError(error)
      }
    })
    present(alert, animated: true)
  }

  private func reloadKeys() {
    records = store.records()
    tableView.reloadData()
  }

  private func presentError(_ error: Error) {
    let alert = UIAlertController(title: "SSH key", message: error.localizedDescription, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    present(alert, animated: true)
  }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    records.count
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let record = records[indexPath.row]
    let cell = tableView.dequeueReusableCell(withIdentifier: "key")
      ?? UITableViewCell(style: .subtitle, reuseIdentifier: "key")
    cell.textLabel?.text = record.id
    cell.detailTextLabel?.text = record.type
    cell.accessoryType = .disclosureIndicator
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    let record = records[indexPath.row]
    let alert = UIAlertController(title: record.id, message: record.publicKey, preferredStyle: .actionSheet)
    alert.addAction(UIAlertAction(title: "Copy public key", style: .default) { _ in
      UIPasteboard.general.string = record.publicKey
    })
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    present(alert, animated: true)
  }

  override func tableView(
    _ tableView: UITableView,
    commit editingStyle: UITableViewCell.EditingStyle,
    forRowAt indexPath: IndexPath
  ) {
    guard editingStyle == .delete else { return }
    do {
      try store.deleteKey(id: records[indexPath.row].id)
      reloadKeys()
    } catch {
      presentError(error)
    }
  }
}
