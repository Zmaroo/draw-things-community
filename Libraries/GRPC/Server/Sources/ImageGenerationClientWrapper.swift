import Atomics
import BinaryResources
import Foundation
import GRPCCore
import GRPCImageServiceModels
import GRPCNIOTransportHTTP2
import ModelZoo
import NIO

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public final class ImageGenerationClientWrapper {
  public final class MonitoringHandler: ChannelDuplexHandler {
    public struct Statistics {
      public var bytesSent: Int
      public var bytesReceived: Int
      public init(bytesSent: Int, bytesReceived: Int) {
        self.bytesSent = bytesSent
        self.bytesReceived = bytesReceived
      }
    }
    public static var statistics: Statistics {
      return Statistics(
        bytesSent: bytesSent.load(ordering: .acquiring),
        bytesReceived: bytesReceived.load(ordering: .acquiring))
    }
    private static let bytesSent = ManagedAtomic<Int>(0)
    private static let bytesReceived = ManagedAtomic<Int>(0)

    public typealias InboundIn = ByteBuffer
    public typealias InboundOut = ByteBuffer
    public typealias OutboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
      // Unwrap the NIOAny to get a ByteBuffer
      let buffer = self.unwrapInboundIn(data)
      let byteCount = buffer.readableBytes
      Self.bytesReceived.wrappingIncrement(by: byteCount, ordering: .acquiringAndReleasing)
      // Forward the bytes we read
      context.fireChannelRead(data)
    }

    public func write(
      context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?
    ) {
      // Unwrap the NIOAny to get a ByteBuffer
      let buffer = self.unwrapOutboundIn(data)
      let byteCount = buffer.readableBytes
      Self.bytesSent.wrappingIncrement(by: byteCount, ordering: .acquiringAndReleasing)
      // Forward the bytes
      context.write(data, promise: promise)
    }
  }
  public enum Error: Swift.Error {
    case invalidRootCA
  }
  private var deviceName: String? = nil
  private var grpcClient: GRPCClient<HTTP2ClientTransport.Posix>? = nil
  private var runConnectionsTask: Task<Void, Never>? = nil
  public private(set) var sharedSecret: String? = nil
  public private(set) var client: (any ImageGenerationService.ClientProtocol)? = nil

  public init(deviceName: String? = nil) {
    self.deviceName = deviceName
  }

  public func connect(
    host: String, port: Int, TLS: Bool, hostnameVerification: Bool, sharedSecret: String?
  ) throws {
    grpcClient?.beginGracefulShutdown()
    runConnectionsTask?.cancel()

    let transportSecurity: HTTP2ClientTransport.Posix.TransportSecurity
    if TLS {
      let rootCABytes = [UInt8](BinaryResources.root_ca_crt)
      guard rootCABytes.count > 0 else {
        throw ImageGenerationClientWrapper.Error.invalidRootCA
      }
      let isrgRootBytes = [UInt8](BinaryResources.isrgrootx1_pem)

      transportSecurity = .tls(
        .defaults {
          var certificates: [TLSConfig.CertificateSource] = [
            .bytes(rootCABytes, format: .pem)
          ]
          if !isrgRootBytes.isEmpty {
            certificates.append(.bytes(isrgRootBytes, format: .pem))
          }
          $0.trustRoots = .certificates(certificates)
          $0.serverCertificateVerification =
            hostnameVerification ? .fullVerification : .noHostnameVerification
        })
    } else {
      transportSecurity = .plaintext
    }
    let transport = try HTTP2ClientTransport.Posix(
      target: .dns(host: host, port: port),
      transportSecurity: transportSecurity
    )
    let grpcClient = GRPCClient(transport: transport)
    let client = ImageGenerationService.Client(wrapping: grpcClient)
    self.grpcClient = grpcClient
    self.client = client
    self.runConnectionsTask = Task {
      do {
        try await grpcClient.runConnections()
      } catch {
        print("image generation client connection loop failed: \(error)")
      }
    }
    self.sharedSecret = sharedSecret
  }

  public func disconnect() throws {
    grpcClient?.beginGracefulShutdown()
    runConnectionsTask?.cancel()
    runConnectionsTask = nil
    grpcClient = nil
    client = nil
    sharedSecret = nil
  }

  deinit {
    grpcClient?.beginGracefulShutdown()
    runConnectionsTask?.cancel()
  }

  public struct LabHours {
    public var community: Int
    public var plus: Int
    public var expireAt: Date
    public init(community: Int, plus: Int, expireAt: Date) {
      self.community = community
      self.plus = plus
      self.expireAt = expireAt
    }
  }

  public func hours(callback: @escaping (LabHours?) -> Void) {
    guard let client = client else {
      callback(nil)
      return
    }
    let request = HoursRequest()
    Task {
      do {
        let result = try await client.hours(request)
        if result.hasThresholds {
          let thresholds = result.thresholds
          callback(
            LabHours(
              community: Int(thresholds.community), plus: Int(thresholds.plus),
              expireAt: Date(timeIntervalSince1970: TimeInterval(thresholds.expireAt))))
        } else {
          callback(nil)
        }
      } catch {
        callback(nil)
      }
    }
  }

  public func echo(
    callback: @escaping (
      Bool, Bool,
      (
        files: [String], models: [ModelZoo.Specification], LoRAs: [LoRAZoo.Specification],
        controlNets: [ControlNetZoo.Specification],
        textualInversions: [TextualInversionZoo.Specification]
      ),
      LabHours?, UInt64
    ) -> Void
  ) {
    guard let client = client else {
      callback(
        false, false, (files: [], models: [], LoRAs: [], controlNets: [], textualInversions: []),
        nil, 0)
      return
    }

    var request = EchoRequest()
    request.name = deviceName ?? ""
    if let sharedSecret = sharedSecret {
      request.sharedSecret = sharedSecret
    }

    Task {
      do {
        let result = try await client.echo(request)
        let jsonDecoder = JSONDecoder()
        jsonDecoder.keyDecodingStrategy = .convertFromSnakeCase
        let models =
          (try? jsonDecoder.decode(
            [FailableDecodable<ModelZoo.Specification>].self, from: result.override.models
          ).compactMap({ $0.value })) ?? []
        let loras =
          (try? jsonDecoder.decode(
            [FailableDecodable<LoRAZoo.Specification>].self, from: result.override.loras
          ).compactMap({ $0.value })) ?? []
        let controlNets =
          (try? jsonDecoder.decode(
            [FailableDecodable<ControlNetZoo.Specification>].self, from: result.override.controlNets
          ).compactMap({ $0.value })) ?? []
        let textualInversions =
          (try? jsonDecoder.decode(
            [FailableDecodable<TextualInversionZoo.Specification>].self,
            from: result.override.textualInversions
          ).compactMap({ $0.value })) ?? []
        let labHours: LabHours? = {
          guard result.hasThresholds else { return nil }
          return LabHours(
            community: Int(result.thresholds.community), plus: Int(result.thresholds.plus),
            expireAt: Date(timeIntervalSince1970: TimeInterval(result.thresholds.expireAt)))
        }()
        callback(
          true, !result.sharedSecretMissing,
          (
            files: result.files, models: models, LoRAs: loras, controlNets: controlNets,
            textualInversions: textualInversions
          ), labHours, result.serverIdentifier)
      } catch {
        callback(
          false, false, (files: [], models: [], LoRAs: [], controlNets: [], textualInversions: []),
          nil, 0)
      }
    }
  }

  public typealias FileExistsCall = Task<Void, Never>

  public func filesExists(
    files: [String], filesToMatch: [String],
    callback: @escaping (Bool, [(String, Bool, Data)]) -> Void
  ) -> Task<Void, Never>? {
    guard let client = client else {
      callback(false, [])
      return nil
    }

    var request = FileListRequest()
    request.files = files
    request.filesWithHash = filesToMatch
    if let sharedSecret = sharedSecret {
      request.sharedSecret = sharedSecret
    }

    let task = Task {
      do {
        let response = try await client.filesExist(request)
        let payload = zip(response.files, response.existences).enumerated().map { index, item in
          (item.0, item.1, index < response.hashes.count ? response.hashes[index] : Data())
        }
        callback(true, payload)
      } catch {
        callback(false, [])
      }
    }
    return task
  }
}
