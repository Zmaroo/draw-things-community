import GRPC
import GRPCImageServiceModels
import NIO

public protocol ImageGenerationServiceClientInterceptorFactoryProtocol: Sendable {
  func makeGenerateImageInterceptors() -> [ClientInterceptor<
    ImageGenerationRequest, ImageGenerationResponse
  >]
  func makeFilesExistInterceptors() -> [ClientInterceptor<FileListRequest, FileExistenceResponse>]
  func makeUploadFileInterceptors() -> [ClientInterceptor<FileUploadRequest, UploadResponse>]
  func makeEchoInterceptors() -> [ClientInterceptor<EchoRequest, EchoReply>]
  func makePubkeyInterceptors() -> [ClientInterceptor<PubkeyRequest, PubkeyResponse>]
  func makeHoursInterceptors() -> [ClientInterceptor<HoursRequest, HoursResponse>]
}

public enum ImageGenerationServiceClientMetadata {
  public enum Methods {
    public static let generateImage = "/ImageGenerationService/GenerateImage"
    public static let filesExist = "/ImageGenerationService/FilesExist"
    public static let uploadFile = "/ImageGenerationService/UploadFile"
    public static let echo = "/ImageGenerationService/Echo"
    public static let pubkey = "/ImageGenerationService/Pubkey"
    public static let hours = "/ImageGenerationService/Hours"
  }
}

public protocol ImageGenerationServiceClientProtocol: GRPCClient {
  var interceptors: ImageGenerationServiceClientInterceptorFactoryProtocol? { get }

  func generateImage(
    _ request: ImageGenerationRequest,
    callOptions: CallOptions?,
    handler: @escaping (ImageGenerationResponse) -> Void
  ) -> ServerStreamingCall<ImageGenerationRequest, ImageGenerationResponse>

  func filesExist(
    _ request: FileListRequest,
    callOptions: CallOptions?
  ) -> UnaryCall<FileListRequest, FileExistenceResponse>

  func uploadFile(
    callOptions: CallOptions?,
    handler: @escaping (UploadResponse) -> Void
  ) -> BidirectionalStreamingCall<FileUploadRequest, UploadResponse>

  func echo(_ request: EchoRequest, callOptions: CallOptions?) -> UnaryCall<EchoRequest, EchoReply>
  func pubkey(_ request: PubkeyRequest, callOptions: CallOptions?) -> UnaryCall<
    PubkeyRequest, PubkeyResponse
  >
  func hours(_ request: HoursRequest, callOptions: CallOptions?) -> UnaryCall<
    HoursRequest, HoursResponse
  >
}

extension ImageGenerationServiceClientProtocol {
  public func generateImage(
    _ request: ImageGenerationRequest,
    callOptions: CallOptions? = nil,
    handler: @escaping (ImageGenerationResponse) -> Void
  ) -> ServerStreamingCall<ImageGenerationRequest, ImageGenerationResponse> {
    self.makeServerStreamingCall(
      path: ImageGenerationServiceClientMetadata.Methods.generateImage,
      request: request,
      callOptions: callOptions ?? self.defaultCallOptions,
      interceptors: self.interceptors?.makeGenerateImageInterceptors() ?? [],
      handler: handler)
  }

  public func filesExist(
    _ request: FileListRequest,
    callOptions: CallOptions? = nil
  ) -> UnaryCall<FileListRequest, FileExistenceResponse> {
    self.makeUnaryCall(
      path: ImageGenerationServiceClientMetadata.Methods.filesExist,
      request: request,
      callOptions: callOptions ?? self.defaultCallOptions,
      interceptors: self.interceptors?.makeFilesExistInterceptors() ?? [])
  }

  public func uploadFile(
    callOptions: CallOptions? = nil,
    handler: @escaping (UploadResponse) -> Void
  ) -> BidirectionalStreamingCall<FileUploadRequest, UploadResponse> {
    self.makeBidirectionalStreamingCall(
      path: ImageGenerationServiceClientMetadata.Methods.uploadFile,
      callOptions: callOptions ?? self.defaultCallOptions,
      interceptors: self.interceptors?.makeUploadFileInterceptors() ?? [],
      handler: handler)
  }

  public func echo(_ request: EchoRequest, callOptions: CallOptions? = nil) -> UnaryCall<
    EchoRequest, EchoReply
  > {
    self.makeUnaryCall(
      path: ImageGenerationServiceClientMetadata.Methods.echo,
      request: request,
      callOptions: callOptions ?? self.defaultCallOptions,
      interceptors: self.interceptors?.makeEchoInterceptors() ?? [])
  }

  public func pubkey(_ request: PubkeyRequest, callOptions: CallOptions? = nil) -> UnaryCall<
    PubkeyRequest, PubkeyResponse
  > {
    self.makeUnaryCall(
      path: ImageGenerationServiceClientMetadata.Methods.pubkey,
      request: request,
      callOptions: callOptions ?? self.defaultCallOptions,
      interceptors: self.interceptors?.makePubkeyInterceptors() ?? [])
  }

  public func hours(_ request: HoursRequest, callOptions: CallOptions? = nil) -> UnaryCall<
    HoursRequest, HoursResponse
  > {
    self.makeUnaryCall(
      path: ImageGenerationServiceClientMetadata.Methods.hours,
      request: request,
      callOptions: callOptions ?? self.defaultCallOptions,
      interceptors: self.interceptors?.makeHoursInterceptors() ?? [])
  }
}

public struct ImageGenerationServiceNIOClient: ImageGenerationServiceClientProtocol {
  public var channel: GRPCChannel
  public var defaultCallOptions: CallOptions
  public var interceptors: ImageGenerationServiceClientInterceptorFactoryProtocol?

  public init(
    channel: GRPCChannel,
    defaultCallOptions: CallOptions = CallOptions(),
    interceptors: ImageGenerationServiceClientInterceptorFactoryProtocol? = nil
  ) {
    self.channel = channel
    self.defaultCallOptions = defaultCallOptions
    self.interceptors = interceptors
  }
}

public protocol ImageGenerationServiceServerInterceptorFactoryProtocol: Sendable {
  func makeGenerateImageInterceptors() -> [ServerInterceptor<
    ImageGenerationRequest, ImageGenerationResponse
  >]
  func makeFilesExistInterceptors() -> [ServerInterceptor<FileListRequest, FileExistenceResponse>]
  func makeUploadFileInterceptors() -> [ServerInterceptor<FileUploadRequest, UploadResponse>]
  func makeEchoInterceptors() -> [ServerInterceptor<EchoRequest, EchoReply>]
  func makePubkeyInterceptors() -> [ServerInterceptor<PubkeyRequest, PubkeyResponse>]
  func makeHoursInterceptors() -> [ServerInterceptor<HoursRequest, HoursResponse>]
}

public protocol ImageGenerationServiceProvider: CallHandlerProvider {
  var interceptors: ImageGenerationServiceServerInterceptorFactoryProtocol? { get }

  func generateImage(
    request: ImageGenerationRequest,
    context: StreamingResponseCallContext<ImageGenerationResponse>
  ) -> EventLoopFuture<GRPCStatus>

  func filesExist(request: FileListRequest, context: StatusOnlyCallContext) -> EventLoopFuture<
    FileExistenceResponse
  >
  func uploadFile(context: StreamingResponseCallContext<UploadResponse>) -> EventLoopFuture<
    (StreamEvent<FileUploadRequest>) -> Void
  >
  func echo(request: EchoRequest, context: StatusOnlyCallContext) -> EventLoopFuture<EchoReply>
  func pubkey(request: PubkeyRequest, context: StatusOnlyCallContext) -> EventLoopFuture<
    PubkeyResponse
  >
  func hours(request: HoursRequest, context: StatusOnlyCallContext) -> EventLoopFuture<
    HoursResponse
  >
}

extension ImageGenerationServiceProvider {
  public var serviceName: Substring { "ImageGenerationService"[...] }

  public func handle(method name: Substring, context: CallHandlerContext)
    -> GRPCServerHandlerProtocol?
  {
    switch name {
    case "GenerateImage":
      return ServerStreamingServerHandler(
        context: context,
        requestDeserializer: ProtobufDeserializer<ImageGenerationRequest>(),
        responseSerializer: ProtobufSerializer<ImageGenerationResponse>(),
        interceptors: self.interceptors?.makeGenerateImageInterceptors() ?? [],
        userFunction: self.generateImage(request:context:))
    case "FilesExist":
      return UnaryServerHandler(
        context: context,
        requestDeserializer: ProtobufDeserializer<FileListRequest>(),
        responseSerializer: ProtobufSerializer<FileExistenceResponse>(),
        interceptors: self.interceptors?.makeFilesExistInterceptors() ?? [],
        userFunction: self.filesExist(request:context:))
    case "UploadFile":
      return BidirectionalStreamingServerHandler(
        context: context,
        requestDeserializer: ProtobufDeserializer<FileUploadRequest>(),
        responseSerializer: ProtobufSerializer<UploadResponse>(),
        interceptors: self.interceptors?.makeUploadFileInterceptors() ?? [],
        observerFactory: self.uploadFile(context:))
    case "Echo":
      return UnaryServerHandler(
        context: context,
        requestDeserializer: ProtobufDeserializer<EchoRequest>(),
        responseSerializer: ProtobufSerializer<EchoReply>(),
        interceptors: self.interceptors?.makeEchoInterceptors() ?? [],
        userFunction: self.echo(request:context:))
    case "Pubkey":
      return UnaryServerHandler(
        context: context,
        requestDeserializer: ProtobufDeserializer<PubkeyRequest>(),
        responseSerializer: ProtobufSerializer<PubkeyResponse>(),
        interceptors: self.interceptors?.makePubkeyInterceptors() ?? [],
        userFunction: self.pubkey(request:context:))
    case "Hours":
      return UnaryServerHandler(
        context: context,
        requestDeserializer: ProtobufDeserializer<HoursRequest>(),
        responseSerializer: ProtobufSerializer<HoursResponse>(),
        interceptors: self.interceptors?.makeHoursInterceptors() ?? [],
        userFunction: self.hours(request:context:))
    default:
      return nil
    }
  }
}
