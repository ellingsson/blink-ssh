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

  private let initialPTY: SSHClient.PTY
  private let hostVerification: SSHClientConfig.RequestVerifyHostCallback
  private let receiveOutput: (Data) -> Void
  private let receiveState: (State) -> Void
  private var connection: SSHClient?
  private var stream: SSH.Stream?
  private var connectionCancellable: AnyCancellable?
  private var resizeCancellable: AnyCancellable?

  private var input: DispatchInputStream?
  private var output: DispatchOutputStream?
  private var errorOutput: DispatchOutputStream?
  private let inputPipe = Pipe()
  private let outputPipe = Pipe()
  private let errorPipe = Pipe()
  private var workerThread: Thread?
  private var proxyTunnel: RecursiveProxyTunnel?

  init(
    profile: SSHProfile,

    initialPTY: SSHClient.PTY,
    hostVerification: @escaping SSHClientConfig.RequestVerifyHostCallback,
    receiveOutput: @escaping (Data) -> Void,
    receiveState: @escaping (State) -> Void
  ) {
    self.profile = profile

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
    let sshDirectory = try KnownHostStore.ensureDefaultDirectory()
    let targetAuthMethod = AuthPublicKey(privateKey: privateKey, keyName: keyID)
    let profiles = try SSHProfileStore(fileURL: SSHProfileStore.defaultURL).load()
    let proxyRoute = try ProxyJumpRoute.resolve(destination: profile, profiles: profiles).map { hop in
      guard let keyID = hop.keyID else { throw DirectSSHSessionError.missingProxyKey }
      return ResolvedProxyHop(endpoint: hop, authMethod: AuthPublicKey(privateKey: try keyStore.privateKey(for: keyID), keyName: keyID))
    }
    installOutputReaders()
    receiveState(.connecting)

    connectToTarget(authMethod: targetAuthMethod, sshDirectory: sshDirectory, proxyRoute: proxyRoute)
    } catch {
      fail(error)
    }
  }

  private func connectToTarget(
    authMethod: AuthPublicKey,
    sshDirectory: String,
    proxyRoute: [ResolvedProxyHop]
  ) {
    let config = SSHClientConfig(
      user: profile.user,
      port: String(profile.port),
      proxyCommand: proxyRoute.isEmpty ? nil : "blink-native-proxyjump",
      authMethods: [authMethod],
      verifyHostCallback: hostVerification,
      connectionTimeout: 30,
      sshDirectory: sshDirectory,
      keepAliveInterval: SSHKeepAlive.interval
    )

    connectionCancellable = SSHClient.dial(profile.hostName, with: config, withProxy: { [weak self] _, inputFD, outputFD in
      guard let self, !proxyRoute.isEmpty else {
        shutdown(inputFD, SHUT_RDWR)
        shutdown(outputFD, SHUT_RDWR)
        return
      }
      let tunnel = RecursiveProxyTunnel(
        route: proxyRoute,
        destination: ProxyDestination(host: self.profile.hostName, port: self.profile.port),
        hostVerification: self.hostVerification,
        sshDirectory: sshDirectory,
        onFailure: { [weak self] error in self?.fail(error) }
      )
      self.proxyTunnel = tunnel
      tunnel.start(inputFD: inputFD, outputFD: outputFD)
    })
      .flatMap { [weak self] connection -> AnyPublisher<SSH.Stream, Error> in
        guard let self else { return .fail(error: DirectSSHSessionError.cancelled) }
        self.connection = connection
        connection.handleSessionException = { [weak self] error in self?.fail(error) }
        return connection.requestInteractiveShell(
          withPTY: self.initialPTY,
          withEnvVars: [
            "LANG": "en_US.UTF-8",
            "LC_CTYPE": "en_US.UTF-8",
          ],
          withAgentForwarding: false
        )
      }
      .sink(
        receiveCompletion: { [weak self] completion in
          if case .failure(let error) = completion { self?.fail(error) }
        },
        receiveValue: { [weak self] stream in
          guard let self else { return }
          self.attach(stream)
          if let startupInput = self.profile.interactiveStartupInput {
            self.send(startupInput)
          }
        }
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
    proxyTunnel?.close()
    proxyTunnel = nil
    stream?.cancel()
    stream = nil

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

}

private enum DirectSSHSessionError: LocalizedError {
  case missingUser
  case missingKey
  case missingProxyKey
  case cancelled


  var errorDescription: String? {
    switch self {
    case .missingUser: return "The SSH profile needs a user name."
    case .missingKey: return "Select an SSH key in the profile first."
    case .missingProxyKey: return "Select an SSH key in the ProxyJump profile first."
    case .cancelled: return "The SSH connection was cancelled."
    }
  }
}

private struct ResolvedProxyHop {
  let endpoint: ProxyJumpHop
  let authMethod: AuthPublicKey
}

private struct ProxyDestination {
  let host: String
  let port: Int
}

private final class RecursiveProxyTunnel {
  private let route: [ResolvedProxyHop]
  private let destination: ProxyDestination
  private let hostVerification: SSHClientConfig.RequestVerifyHostCallback
  private let sshDirectory: String
  private let onFailure: (Error) -> Void
  private var connection: SSHClient?
  private var forwardingStream: SSH.Stream?
  private var cancellable: AnyCancellable?
  private var output: DispatchOutputStream?
  private var input: DispatchInputStream?
  private var upstreamTunnel: RecursiveProxyTunnel?
  private var workerThread: Thread?

  init(
    route: [ResolvedProxyHop],
    destination: ProxyDestination,
    hostVerification: @escaping SSHClientConfig.RequestVerifyHostCallback,
    sshDirectory: String,
    onFailure: @escaping (Error) -> Void
  ) {
    self.route = route
    self.destination = destination
    self.hostVerification = hostVerification
    self.sshDirectory = sshDirectory
    self.onFailure = onFailure
  }

  func start(inputFD: Int32, outputFD: Int32) {
    guard let hop = route.first else {
      shutdown(inputFD, SHUT_RDWR)
      shutdown(outputFD, SHUT_RDWR)
      return
    }
    let worker = Thread { [weak self] in
      self?.connect(hop: hop, inputFD: inputFD, outputFD: outputFD)
      RunLoop.current.run()
    }
    worker.name = "BlinkSSH recursive proxy connection"
    workerThread = worker
    worker.start()
  }

  private func connect(hop: ResolvedProxyHop, inputFD: Int32, outputFD: Int32) {
    let hasUpstream = route.count > 1
    let config = SSHClientConfig(
      user: hop.endpoint.user,
      port: String(hop.endpoint.port),
      proxyCommand: hasUpstream ? "blink-native-proxyjump" : nil,
      authMethods: [hop.authMethod],
      verifyHostCallback: hostVerification,
      connectionTimeout: 30,
      sshDirectory: sshDirectory,
      keepAliveInterval: SSHKeepAlive.interval
    )
    cancellable = SSHClient.dial(hop.endpoint.host, with: config, withProxy: { [weak self] _, nestedInputFD, nestedOutputFD in
      guard let self, self.route.count > 1 else {
        shutdown(nestedInputFD, SHUT_RDWR)
        shutdown(nestedOutputFD, SHUT_RDWR)
        return
      }
      let tunnel = RecursiveProxyTunnel(
        route: Array(self.route.dropFirst()),
        destination: ProxyDestination(host: hop.endpoint.host, port: hop.endpoint.port),
        hostVerification: self.hostVerification,
        sshDirectory: self.sshDirectory,
        onFailure: self.onFailure
      )
      self.upstreamTunnel = tunnel
      tunnel.start(inputFD: nestedInputFD, outputFD: nestedOutputFD)
    })
      .flatMap { [weak self] connection -> AnyPublisher<SSH.Stream, Error> in
        guard let self else { return .fail(error: DirectSSHSessionError.cancelled) }
        self.connection = connection
        connection.handleSessionException = { [weak self] error in self?.onFailure(error) }
        return connection.requestForward(to: self.destination.host, port: Int32(self.destination.port), from: "127.0.0.1", localPort: 0)
      }
      .sink(receiveCompletion: { [weak self] completion in
        if case .failure(let error) = completion { self?.onFailure(error) }
      }, receiveValue: { [weak self] stream in
        guard let self else { return }
        let output = DispatchOutputStream(stream: dup(outputFD))
        let input = DispatchInputStream(stream: dup(inputFD))
        stream.handleFailure = { [weak self] error in self?.onFailure(error) }
        stream.connect(stdout: output, stdin: input)
        self.forwardingStream = stream
        self.output = output
        self.input = input
      })
  }

  func close() {
    cancellable?.cancel()
    cancellable = nil
    forwardingStream?.cancel()
    forwardingStream = nil
    input?.close()
    input = nil
    output?.close()
    output = nil
    upstreamTunnel?.close()
    upstreamTunnel = nil
  }
}
