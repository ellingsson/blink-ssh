import Combine
import Darwin
import Dispatch
import Foundation
import SSH

final class DirectSSHSession {
  enum State: Equatable {
    case connecting
    case connected
    case closed
    case failed(String)
  }

  private let profile: SSHProfile
  private let proxyProfile: SSHProfile?
  private let initialPTY: SSHClient.PTY
  private let hostVerification: SSHClientConfig.RequestVerifyHostCallback
  private let receiveOutput: (Data) -> Void
  private let receiveState: (State) -> Void
  private var connection: SSHClient?
  private var stream: SSH.Stream?
  private var connectionCancellable: AnyCancellable?
  private var resizeCancellable: AnyCancellable?
  private var proxyStream: SSH.Stream?
  private var proxyCancellable: AnyCancellable?
  private var proxyInput: DispatchInputStream?
  private var proxyOutput: DispatchOutputStream?
  private var input: DispatchInputStream?
  private var output: DispatchOutputStream?
  private var errorOutput: DispatchOutputStream?
  private let inputPipe = Pipe()
  private let outputPipe = Pipe()
  private let errorPipe = Pipe()
  private var workerThread: Thread?
  private var proxyWorkerThread: Thread?
  private var proxyConnection: SSHClient?
  private var proxyHasStarted = false

  init(
    profile: SSHProfile,
    proxyProfile: SSHProfile?,
    initialPTY: SSHClient.PTY,
    hostVerification: @escaping SSHClientConfig.RequestVerifyHostCallback,
    receiveOutput: @escaping (Data) -> Void,
    receiveState: @escaping (State) -> Void
  ) {
    self.profile = profile
    self.proxyProfile = proxyProfile
    self.initialPTY = initialPTY
    self.hostVerification = hostVerification
    self.receiveOutput = receiveOutput
    self.receiveState = receiveState
  }

  func start() {
    let worker = Thread { [weak self] in
      self?.startOnWorker()
      RunLoop.current.run()
    }
    worker.name = "BlinkSSH connection"
    workerThread = worker
    worker.start()
  }

  private func startOnWorker() {
    do {
    guard !profile.user.isEmpty else {
      throw DirectSSHSessionError.missingUser
    }
    guard let keyID = profile.keyID else {
      throw DirectSSHSessionError.missingKey
    }

    let keyStore = SSHKeyStore()
    let privateKey = try keyStore.privateKey(for: keyID)
    let sshDirectory = try Self.knownHostsDirectory()
    let targetAuthMethod = AuthPublicKey(privateKey: privateKey, keyName: keyID)
    let proxyJump: ProxyJumpEndpoint?
    let proxyKeyID: String?
    if let proxyProfile {
      guard proxyProfile.proxyJump == nil else { throw DirectSSHSessionError.nestedProxyJump }
      proxyJump = ProxyJumpEndpoint(profile: proxyProfile)
      proxyKeyID = proxyProfile.keyID
    } else {
      proxyJump = try profile.proxyJump.map(ProxyJumpEndpoint.init)
      proxyKeyID = keyID
    }
    installOutputReaders()
    receiveState(.connecting)

    if let proxyJump {
      guard let proxyKeyID else { throw DirectSSHSessionError.missingProxyKey }
      let proxyPrivateKey = try keyStore.privateKey(for: proxyKeyID)
      let proxyAuthMethod = AuthPublicKey(privateKey: proxyPrivateKey, keyName: proxyKeyID)
      connectToTarget(
        authMethod: targetAuthMethod,
        sshDirectory: sshDirectory,
        proxyJump: proxyJump,
        proxyAuthMethod: proxyAuthMethod
      )
    } else {
      connectToTarget(
        authMethod: targetAuthMethod,
        sshDirectory: sshDirectory,
        proxyJump: nil,
        proxyAuthMethod: nil
      )
    }
    } catch {
      fail(error)
    }
  }

  private func connectToTarget(
    authMethod: AuthPublicKey,
    sshDirectory: String,
    proxyJump: ProxyJumpEndpoint?,
    proxyAuthMethod: AuthPublicKey?
  ) {
    let config = SSHClientConfig(
      user: profile.user,
      port: String(profile.port),
      proxyCommand: proxyJump == nil ? nil : "blink-native-proxyjump",
      authMethods: [authMethod],
      verifyHostCallback: hostVerification,
      connectionTimeout: 30,
      sshDirectory: sshDirectory
    )

    connectionCancellable = SSHClient.dial(profile.hostName, with: config, withProxy: { [weak self] _, inputFD, outputFD in
      guard let self, let proxyJump, let proxyAuthMethod else {
        shutdown(inputFD, SHUT_RDWR)
        shutdown(outputFD, SHUT_RDWR)
        return
      }
      self.startProxyWorker(proxyJump, authMethod: proxyAuthMethod, sshDirectory: sshDirectory, inputFD: inputFD, outputFD: outputFD)
    })
      .flatMap { [weak self] connection -> AnyPublisher<SSH.Stream, Error> in
        guard let self else { return .fail(error: DirectSSHSessionError.cancelled) }
        self.connection = connection
        connection.handleSessionException = { [weak self] error in self?.fail(error) }
        if let command = self.profile.command, !command.isEmpty {
          return connection.requestExec(
            command: command,
            withPTY: self.initialPTY,
            withEnvVars: [:],
            withAgentForwarding: false
          )
        }
        return connection.requestInteractiveShell(
          withPTY: self.initialPTY,
          withEnvVars: [:],
          withAgentForwarding: false
        )
      }
      .sink(
        receiveCompletion: { [weak self] completion in
          if case .failure(let error) = completion { self?.fail(error) }
        },
        receiveValue: { [weak self] stream in self?.attach(stream) }
      )
  }

  func send(_ data: Data) {
    inputPipe.fileHandleForWriting.write(data)
  }

  func resize(rows: Int, columns: Int) {
    guard rows > 0, columns > 0, let stream else { return }
    resizeCancellable?.cancel()
    resizeCancellable = stream.resizePty(rows: Int32(rows), columns: Int32(columns))
      .sink(
        receiveCompletion: { [weak self] completion in
          if case .failure(let error) = completion { self?.fail(error) }
        },
        receiveValue: { }
      )
  }

  func close(reportClosed: Bool = true) {
    connectionCancellable?.cancel()
    connectionCancellable = nil
    resizeCancellable?.cancel()
    resizeCancellable = nil
    proxyCancellable?.cancel()
    proxyCancellable = nil
    stream?.cancel()
    stream = nil
    proxyStream?.cancel()
    proxyStream = nil
    proxyInput?.close()
    proxyInput = nil
    proxyOutput?.close()
    proxyOutput = nil
    input?.close()
    output?.close()
    errorOutput?.close()
    input = nil
    output = nil
    errorOutput = nil
    outputPipe.fileHandleForReading.readabilityHandler = nil
    errorPipe.fileHandleForReading.readabilityHandler = nil
    if reportClosed {
      receiveState(.closed)
    }
  }

  private func attach(_ stream: SSH.Stream) {
    let output = DispatchOutputStream(stream: dup(outputPipe.fileHandleForWriting.fileDescriptor))
    let errorOutput = DispatchOutputStream(stream: dup(errorPipe.fileHandleForWriting.fileDescriptor))
    let input = DispatchInputStream(stream: dup(inputPipe.fileHandleForReading.fileDescriptor))
    stream.handleCompletion = { [weak self] in self?.close() }
    stream.handleFailure = { [weak self] error in self?.fail(error) }
    stream.connect(stdout: output, stdin: input, stderr: errorOutput)
    self.stream = stream
    self.output = output
    self.errorOutput = errorOutput
    self.input = input
    receiveState(.connected)
  }

  private func connectThroughProxy(
    _ proxy: ProxyJumpEndpoint,
    authMethod: AuthPublicKey,
    sshDirectory: String,
    inputFD: Int32,
    outputFD: Int32
  ) {
    let config = SSHClientConfig(user: proxy.user ?? profile.user, port: String(proxy.port), authMethods: [authMethod], verifyHostCallback: hostVerification, connectionTimeout: 30, sshDirectory: sshDirectory)
    proxyCancellable = SSHClient.dial(proxy.host, with: config)
      .flatMap { [weak self] connection -> AnyPublisher<SSH.Stream, Error> in
        guard let self else { return .fail(error: DirectSSHSessionError.cancelled) }
        self.proxyConnection = connection
        return connection.requestForward(to: self.profile.hostName, port: Int32(self.profile.port), from: "127.0.0.1", localPort: 0)
      }
      .sink(receiveCompletion: { [weak self] completion in
        if case .failure(let error) = completion { self?.fail(error) }
      }, receiveValue: { [weak self] stream in
        guard let self else { return }
        let output = DispatchOutputStream(stream: dup(outputFD))
        let input = DispatchInputStream(stream: dup(inputFD))
        stream.handleFailure = { [weak self] error in self?.fail(error) }
        stream.connect(stdout: output, stdin: input)
        self.proxyStream = stream
        self.proxyOutput = output
        self.proxyInput = input
      })
  }

  private func startProxyWorker(
    _ proxy: ProxyJumpEndpoint,
    authMethod: AuthPublicKey,
    sshDirectory: String,
    inputFD: Int32,
    outputFD: Int32
  ) {
    guard !proxyHasStarted else { return }
    proxyHasStarted = true
    let worker = Thread { [weak self] in
      self?.connectThroughProxy(proxy, authMethod: authMethod, sshDirectory: sshDirectory, inputFD: inputFD, outputFD: outputFD)
      RunLoop.current.run()
    }
    worker.name = "BlinkSSH proxy connection"
    proxyWorkerThread = worker
    worker.start()
  }

  private func installOutputReaders() {
    let handle: (FileHandle) -> Void = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      self?.receiveOutput(data)
    }
    outputPipe.fileHandleForReading.readabilityHandler = handle
    errorPipe.fileHandleForReading.readabilityHandler = handle
  }

  private func fail(_ error: Error) {
    receiveState(.failed(error.localizedDescription))
    close(reportClosed: false)
  }

  private static func knownHostsDirectory() throws -> String {
    let directory = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    .appendingPathComponent("BlinkSSH/ssh", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.path
  }
}

private enum DirectSSHSessionError: LocalizedError {
  case missingUser
  case missingKey
  case missingProxyKey
  case cancelled
  case unsupportedProxyJump
  case nestedProxyJump

  var errorDescription: String? {
    switch self {
    case .missingUser: return "The SSH profile needs a user name."
    case .missingKey: return "Select an SSH key in the profile first."
    case .missingProxyKey: return "Select an SSH key in the ProxyJump profile first."
    case .cancelled: return "The SSH connection was cancelled."
    case .unsupportedProxyJump: return "ProxyJump supports one [user@]host[:port] hop."
    case .nestedProxyJump: return "The selected ProxyJump profile must not have its own ProxyJump."
    }
  }
}

private struct ProxyJumpEndpoint {
  let user: String?
  let host: String
  let port: Int

  init(profile: SSHProfile) {
    user = profile.user.isEmpty ? nil : profile.user
    host = profile.hostName
    port = profile.port
  }

  init(_ value: String) throws {
    guard !value.contains(","), !value.contains(" ") else { throw DirectSSHSessionError.unsupportedProxyJump }
    let userAndHost = value.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
    let hostPort: Substring
    if userAndHost.count == 2 {
      guard !userAndHost[0].isEmpty else { throw DirectSSHSessionError.unsupportedProxyJump }
      user = String(userAndHost[0])
      hostPort = userAndHost[1]
    } else {
      user = nil
      hostPort = userAndHost[0]
    }
    let parts = hostPort.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    guard !parts[0].isEmpty else { throw DirectSSHSessionError.unsupportedProxyJump }
    host = String(parts[0])
    if parts.count == 2 {
      guard let port = Int(parts[1]), (1...65535).contains(port) else { throw DirectSSHSessionError.unsupportedProxyJump }
      self.port = port
    } else {
      port = 22
    }
  }
}
