import Foundation
import GRPCCore
import GRPCImageServiceModels
import GRPCNIOTransportHTTP2
import Logging

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public final class ProxyGPUClientWrapper {
  public private(set) var deviceName: String? = nil
  private var grpcClient: GRPCClient<HTTP2ClientTransport.Posix>? = nil
  private var runConnectionsTask: Task<Void, Never>? = nil
  public private(set) var client: (any ImageGenerationService.ClientProtocol)? = nil
  private let logger = Logger(label: "com.draw-things.image-generation-proxy-service")
  public init(deviceName: String? = nil) {
    self.deviceName = deviceName
  }

  public func connect(host: String, port: Int) throws {
    grpcClient?.beginGracefulShutdown()
    runConnectionsTask?.cancel()

    let transport = try HTTP2ClientTransport.Posix(
      target: .dns(host: host, port: port),
      transportSecurity: .plaintext
    )
    let grpcClient = GRPCClient(transport: transport)
    let client = ImageGenerationService.Client(wrapping: grpcClient)
    let logger = self.logger
    self.grpcClient = grpcClient
    self.client = client
    self.runConnectionsTask = Task {
      do {
        try await grpcClient.runConnections()
      } catch {
        logger.error("proxy gpu client connection loop failed: \(String(describing: error))")
      }
    }
  }

  public func disconnect() throws {
    grpcClient?.beginGracefulShutdown()
    runConnectionsTask?.cancel()
    runConnectionsTask = nil
    grpcClient = nil
    client = nil
  }

  deinit {
    grpcClient?.beginGracefulShutdown()
    runConnectionsTask?.cancel()
  }

  public func echo() async -> (Bool, [String]) {
    guard let client = client else {
      return (false, [])
    }

    var request = EchoRequest()
    let name = deviceName ?? ""
    request.name = "Proxy Server connect \(name)"
    do {
      let result = try await client.echo(request)
      return (true, result.files)
    } catch {
      return (false, [])
    }
  }

}
