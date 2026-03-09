import Foundation
import GRPCControlPanelModels
import GRPCCore
import GRPCNIOTransportHTTP2

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public final class ProxyControlClient {
  public private(set) var deviceName: String? = nil
  private var grpcClient: GRPCClient<HTTP2ClientTransport.Posix>? = nil
  private var runConnectionsTask: Task<Void, Never>? = nil
  public private(set) var client: (any ControlPanelService.ClientProtocol)? = nil

  public init(deviceName: String? = nil) {
    self.deviceName = deviceName
  }

  public func connect(host: String, port: Int) throws {
    print("connect to proxy server \(host):\(port)")
    grpcClient?.beginGracefulShutdown()
    runConnectionsTask?.cancel()

    let transport = try HTTP2ClientTransport.Posix(
      target: .dns(host: host, port: port),
      transportSecurity: .plaintext
    )
    let grpcClient = GRPCClient(transport: transport)
    let client = ControlPanelService.Client(wrapping: grpcClient)
    self.grpcClient = grpcClient
    self.client = client
    self.runConnectionsTask = Task {
      do {
        try await grpcClient.runConnections()
      } catch {
        print("proxy control client connection loop failed: \(error)")
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

  public func addGPUServer(
    address: String, port: Int, isHighPriority: Bool, completion: @escaping (Bool) -> Void
  ) {
    guard let client = client else {
      print("addGPUServer can not connect to proxy server")
      completion(false)
      return
    }

    var request = GPUServerRequest()
    request.serverConfig.address = address
    request.serverConfig.port = Int32(port)
    request.serverConfig.isHighPriority = isHighPriority
    request.operation = .add

    Task {
      do {
        let result = try await client.manageGPUServer(request)
        print(result.message)
        completion(true)
      } catch {
        print("can not add GPU Server \(address):\(port) to Proxy Server")
        completion(false)
      }
    }

  }

  public func removeGPUServer(address: String, port: Int, completion: @escaping (Bool) -> Void) {
    guard let client = client else {
      print("removeGPUServer can not connect to proxy server")
      completion(false)
      return
    }

    var request = GPUServerRequest()
    request.serverConfig.address = address
    request.serverConfig.port = Int32(port)
    request.operation = .remove

    Task {
      do {
        let result = try await client.manageGPUServer(request)
        print(result.message)
        completion(true)
      } catch {
        print("can not remove GPU Server \(address):\(port) from Proxy Server")
        completion(false)
      }
    }
  }

  public func updateThrottlingPolicy(policies: [String: Int], completion: @escaping (Bool) -> Void)
  {
    guard let client = client else {
      print("updateThrottlingPolicy can not connect to proxy server")
      completion(false)
      return
    }

    var request = ThrottlingRequest()
    request.limitConfig = policies.mapValues { Int32($0) }

    Task {
      do {
        let result = try await client.updateThrottlingConfig(request)
        print("\(result.message)")
        completion(true)
      } catch {
        print("can not update ThrottlingConfig succees")
        completion(false)
      }
    }
  }

  public func updatePem(completion: @escaping (Bool) -> Void) {
    guard let client = client else {
      print("Update PEM can not connect to proxy server")
      completion(false)
      return
    }

    let request = UpdatePemRequest()

    Task {
      do {
        let response = try await client.updatePem(request)
        print("\(response.message)")
        completion(true)
      } catch {
        print("can not update PEM succees on Server")
        completion(false)
      }
    }
  }

  public func updateSharedSecret(completion: @escaping (Bool) -> Void) {
    guard let client = client else {
      print("can not connect to proxy server")
      completion(false)
      return
    }

    let request = UpdateSharedSecretRequest()

    Task {
      do {
        let response = try await client.updateSharedSecret(request)
        print("\(response.message)")
        completion(true)
      } catch {
        print("can not update Shared Secret succees on Server")
        completion(false)
      }
    }
  }

  public func updatePrivateKey(completion: @escaping (Bool) -> Void) {
    guard let client = client else {
      print("can not connect to proxy server")
      completion(false)
      return
    }

    let request = UpdatePrivateKeyRequest()

    Task {
      do {
        let response = try await client.updatePrivateKey(request)
        print("\(response.message)")
        completion(true)
      } catch {
        print("can not update Private Key succees on Server")
        completion(false)
      }
    }
  }

  public func updateModelList(files: [String], completion: @escaping (Bool) -> Void) {
    guard let client = client else {
      print("can not connect to proxy server")
      completion(false)
      return
    }

    var request = UpdateModelListRequest()
    request.files = files
    Task {
      do {
        let response = try await client.updateModelList(request)
        print(response.message)
        completion(true)
      } catch {
        print("can not update Model List")
        completion(false)
      }
    }
  }

  public func updateComputeUnit(
    policies: [String: Int], expirationTimestamp: Int64 = 0, completion: @escaping (Bool) -> Void
  ) {
    guard let client = client else {
      print("updateComputeUnit can not connect to proxy server")
      completion(false)
      return
    }

    var request = UpdateComputeUnitRequest()
    request.cuConfig = policies.mapValues { Int32($0) }
    request.expirationTimestamp = expirationTimestamp

    Task {
      do {
        let result = try await client.updateComputeUnit(request)
        print("\(result.message)")
        completion(true)
      } catch {
        print("can not update ComputeUnit policy")
        completion(false)
      }
    }
  }
}
