import GRPC
import GRPCControlPanelModels
import NIO

public protocol ControlPanelServiceClientInterceptorFactoryProtocol: Sendable {
  func makeManageGPUServerInterceptors() -> [ClientInterceptor<GPUServerRequest, GPUServerResponse>]
  func makeUpdateThrottlingConfigInterceptors() -> [ClientInterceptor<
    ThrottlingRequest, ThrottlingResponse
  >]
  func makeUpdatePemInterceptors() -> [ClientInterceptor<UpdatePemRequest, UpdatePemResponse>]
  func makeUpdateModelListInterceptors() -> [ClientInterceptor<
    UpdateModelListRequest, UpdateModelListResponse
  >]
  func makeUpdateSharedSecretInterceptors() -> [ClientInterceptor<
    UpdateSharedSecretRequest, UpdateSharedSecretResponse
  >]
  func makeUpdatePrivateKeyInterceptors() -> [ClientInterceptor<
    UpdatePrivateKeyRequest, UpdatePrivateKeyResponse
  >]
  func makeUpdateComputeUnitInterceptors() -> [ClientInterceptor<
    UpdateComputeUnitRequest, UpdateComputeUnitResponse
  >]
}

public enum ControlPanelServiceClientMetadata {
  public enum Methods {
    public static let manageGPUServer = "/ControlPanelService/ManageGPUServer"
    public static let updateThrottlingConfig = "/ControlPanelService/UpdateThrottlingConfig"
    public static let updatePem = "/ControlPanelService/UpdatePem"
    public static let updateModelList = "/ControlPanelService/UpdateModelList"
    public static let updateSharedSecret = "/ControlPanelService/UpdateSharedSecret"
    public static let updatePrivateKey = "/ControlPanelService/UpdatePrivateKey"
    public static let updateComputeUnit = "/ControlPanelService/UpdateComputeUnit"
  }
}

public protocol ControlPanelServiceClientProtocol: GRPCClient {
  var interceptors: ControlPanelServiceClientInterceptorFactoryProtocol? { get }

  func manageGPUServer(_ request: GPUServerRequest, callOptions: CallOptions?) -> UnaryCall<
    GPUServerRequest, GPUServerResponse
  >
  func updateThrottlingConfig(_ request: ThrottlingRequest, callOptions: CallOptions?) -> UnaryCall<
    ThrottlingRequest, ThrottlingResponse
  >
  func updatePem(_ request: UpdatePemRequest, callOptions: CallOptions?) -> UnaryCall<
    UpdatePemRequest, UpdatePemResponse
  >
  func updateModelList(_ request: UpdateModelListRequest, callOptions: CallOptions?) -> UnaryCall<
    UpdateModelListRequest, UpdateModelListResponse
  >
  func updateSharedSecret(_ request: UpdateSharedSecretRequest, callOptions: CallOptions?)
    -> UnaryCall<UpdateSharedSecretRequest, UpdateSharedSecretResponse>
  func updatePrivateKey(_ request: UpdatePrivateKeyRequest, callOptions: CallOptions?) -> UnaryCall<
    UpdatePrivateKeyRequest, UpdatePrivateKeyResponse
  >
  func updateComputeUnit(_ request: UpdateComputeUnitRequest, callOptions: CallOptions?)
    -> UnaryCall<UpdateComputeUnitRequest, UpdateComputeUnitResponse>
}

extension ControlPanelServiceClientProtocol {
  public func manageGPUServer(_ request: GPUServerRequest, callOptions: CallOptions? = nil)
    -> UnaryCall<GPUServerRequest, GPUServerResponse>
  {
    self.makeUnaryCall(
      path: ControlPanelServiceClientMetadata.Methods.manageGPUServer,
      request: request,
      callOptions: callOptions ?? self.defaultCallOptions,
      interceptors: self.interceptors?.makeManageGPUServerInterceptors() ?? [])
  }

  public func updateThrottlingConfig(_ request: ThrottlingRequest, callOptions: CallOptions? = nil)
    -> UnaryCall<ThrottlingRequest, ThrottlingResponse>
  {
    self.makeUnaryCall(
      path: ControlPanelServiceClientMetadata.Methods.updateThrottlingConfig,
      request: request,
      callOptions: callOptions ?? self.defaultCallOptions,
      interceptors: self.interceptors?.makeUpdateThrottlingConfigInterceptors() ?? [])
  }

  public func updatePem(_ request: UpdatePemRequest, callOptions: CallOptions? = nil) -> UnaryCall<
    UpdatePemRequest, UpdatePemResponse
  > {
    self.makeUnaryCall(
      path: ControlPanelServiceClientMetadata.Methods.updatePem,
      request: request,
      callOptions: callOptions ?? self.defaultCallOptions,
      interceptors: self.interceptors?.makeUpdatePemInterceptors() ?? [])
  }

  public func updateModelList(_ request: UpdateModelListRequest, callOptions: CallOptions? = nil)
    -> UnaryCall<UpdateModelListRequest, UpdateModelListResponse>
  {
    self.makeUnaryCall(
      path: ControlPanelServiceClientMetadata.Methods.updateModelList,
      request: request,
      callOptions: callOptions ?? self.defaultCallOptions,
      interceptors: self.interceptors?.makeUpdateModelListInterceptors() ?? [])
  }

  public func updateSharedSecret(
    _ request: UpdateSharedSecretRequest, callOptions: CallOptions? = nil
  ) -> UnaryCall<UpdateSharedSecretRequest, UpdateSharedSecretResponse> {
    self.makeUnaryCall(
      path: ControlPanelServiceClientMetadata.Methods.updateSharedSecret,
      request: request,
      callOptions: callOptions ?? self.defaultCallOptions,
      interceptors: self.interceptors?.makeUpdateSharedSecretInterceptors() ?? [])
  }

  public func updatePrivateKey(_ request: UpdatePrivateKeyRequest, callOptions: CallOptions? = nil)
    -> UnaryCall<UpdatePrivateKeyRequest, UpdatePrivateKeyResponse>
  {
    self.makeUnaryCall(
      path: ControlPanelServiceClientMetadata.Methods.updatePrivateKey,
      request: request,
      callOptions: callOptions ?? self.defaultCallOptions,
      interceptors: self.interceptors?.makeUpdatePrivateKeyInterceptors() ?? [])
  }

  public func updateComputeUnit(
    _ request: UpdateComputeUnitRequest, callOptions: CallOptions? = nil
  ) -> UnaryCall<UpdateComputeUnitRequest, UpdateComputeUnitResponse> {
    self.makeUnaryCall(
      path: ControlPanelServiceClientMetadata.Methods.updateComputeUnit,
      request: request,
      callOptions: callOptions ?? self.defaultCallOptions,
      interceptors: self.interceptors?.makeUpdateComputeUnitInterceptors() ?? [])
  }
}

public struct ControlPanelServiceNIOClient: ControlPanelServiceClientProtocol {
  public var channel: GRPCChannel
  public var defaultCallOptions: CallOptions
  public var interceptors: ControlPanelServiceClientInterceptorFactoryProtocol?

  public init(
    channel: GRPCChannel,
    defaultCallOptions: CallOptions = CallOptions(),
    interceptors: ControlPanelServiceClientInterceptorFactoryProtocol? = nil
  ) {
    self.channel = channel
    self.defaultCallOptions = defaultCallOptions
    self.interceptors = interceptors
  }
}

public protocol ControlPanelServiceServerInterceptorFactoryProtocol: Sendable {
  func makeManageGPUServerInterceptors() -> [ServerInterceptor<GPUServerRequest, GPUServerResponse>]
  func makeUpdateThrottlingConfigInterceptors() -> [ServerInterceptor<
    ThrottlingRequest, ThrottlingResponse
  >]
  func makeUpdatePemInterceptors() -> [ServerInterceptor<UpdatePemRequest, UpdatePemResponse>]
  func makeUpdateModelListInterceptors() -> [ServerInterceptor<
    UpdateModelListRequest, UpdateModelListResponse
  >]
  func makeUpdateSharedSecretInterceptors() -> [ServerInterceptor<
    UpdateSharedSecretRequest, UpdateSharedSecretResponse
  >]
  func makeUpdatePrivateKeyInterceptors() -> [ServerInterceptor<
    UpdatePrivateKeyRequest, UpdatePrivateKeyResponse
  >]
  func makeUpdateComputeUnitInterceptors() -> [ServerInterceptor<
    UpdateComputeUnitRequest, UpdateComputeUnitResponse
  >]
}

public protocol ControlPanelServiceProvider: CallHandlerProvider {
  var interceptors: ControlPanelServiceServerInterceptorFactoryProtocol? { get }

  func manageGPUServer(request: GPUServerRequest, context: StatusOnlyCallContext)
    -> EventLoopFuture<GPUServerResponse>
  func updateThrottlingConfig(request: ThrottlingRequest, context: StatusOnlyCallContext)
    -> EventLoopFuture<ThrottlingResponse>
  func updatePem(request: UpdatePemRequest, context: StatusOnlyCallContext) -> EventLoopFuture<
    UpdatePemResponse
  >
  func updateModelList(request: UpdateModelListRequest, context: StatusOnlyCallContext)
    -> EventLoopFuture<UpdateModelListResponse>
  func updateSharedSecret(request: UpdateSharedSecretRequest, context: StatusOnlyCallContext)
    -> EventLoopFuture<UpdateSharedSecretResponse>
  func updatePrivateKey(request: UpdatePrivateKeyRequest, context: StatusOnlyCallContext)
    -> EventLoopFuture<UpdatePrivateKeyResponse>
  func updateComputeUnit(request: UpdateComputeUnitRequest, context: StatusOnlyCallContext)
    -> EventLoopFuture<UpdateComputeUnitResponse>
}

extension ControlPanelServiceProvider {
  public var serviceName: Substring { "ControlPanelService"[...] }

  public func handle(method name: Substring, context: CallHandlerContext)
    -> GRPCServerHandlerProtocol?
  {
    switch name {
    case "ManageGPUServer":
      return UnaryServerHandler(
        context: context,
        requestDeserializer: ProtobufDeserializer<GPUServerRequest>(),
        responseSerializer: ProtobufSerializer<GPUServerResponse>(),
        interceptors: self.interceptors?.makeManageGPUServerInterceptors() ?? [],
        userFunction: self.manageGPUServer(request:context:))
    case "UpdateThrottlingConfig":
      return UnaryServerHandler(
        context: context,
        requestDeserializer: ProtobufDeserializer<ThrottlingRequest>(),
        responseSerializer: ProtobufSerializer<ThrottlingResponse>(),
        interceptors: self.interceptors?.makeUpdateThrottlingConfigInterceptors() ?? [],
        userFunction: self.updateThrottlingConfig(request:context:))
    case "UpdatePem":
      return UnaryServerHandler(
        context: context,
        requestDeserializer: ProtobufDeserializer<UpdatePemRequest>(),
        responseSerializer: ProtobufSerializer<UpdatePemResponse>(),
        interceptors: self.interceptors?.makeUpdatePemInterceptors() ?? [],
        userFunction: self.updatePem(request:context:))
    case "UpdateModelList":
      return UnaryServerHandler(
        context: context,
        requestDeserializer: ProtobufDeserializer<UpdateModelListRequest>(),
        responseSerializer: ProtobufSerializer<UpdateModelListResponse>(),
        interceptors: self.interceptors?.makeUpdateModelListInterceptors() ?? [],
        userFunction: self.updateModelList(request:context:))
    case "UpdateSharedSecret":
      return UnaryServerHandler(
        context: context,
        requestDeserializer: ProtobufDeserializer<UpdateSharedSecretRequest>(),
        responseSerializer: ProtobufSerializer<UpdateSharedSecretResponse>(),
        interceptors: self.interceptors?.makeUpdateSharedSecretInterceptors() ?? [],
        userFunction: self.updateSharedSecret(request:context:))
    case "UpdatePrivateKey":
      return UnaryServerHandler(
        context: context,
        requestDeserializer: ProtobufDeserializer<UpdatePrivateKeyRequest>(),
        responseSerializer: ProtobufSerializer<UpdatePrivateKeyResponse>(),
        interceptors: self.interceptors?.makeUpdatePrivateKeyInterceptors() ?? [],
        userFunction: self.updatePrivateKey(request:context:))
    case "UpdateComputeUnit":
      return UnaryServerHandler(
        context: context,
        requestDeserializer: ProtobufDeserializer<UpdateComputeUnitRequest>(),
        responseSerializer: ProtobufSerializer<UpdateComputeUnitResponse>(),
        interceptors: self.interceptors?.makeUpdateComputeUnitInterceptors() ?? [],
        userFunction: self.updateComputeUnit(request:context:))
    default:
      return nil
    }
  }
}
