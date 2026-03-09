import Atomics
import Crypto
import DataModels
import Diffusion
import Foundation
import GRPCCore
import GRPCImageServiceModels
import ImageGenerator
import Logging
import ModelZoo
import NNC
import ScriptDataModels
import ServerConfigurationRewriter

extension ImageGeneratorSignpost {
  public init(from signpostProto: ImageGenerationSignpostProto) {
    switch signpostProto.signpost {
    case .textEncoded:
      self = .textEncoded
    case .imageEncoded:
      self = .imageEncoded
    case .sampling(let sampling):
      self = .sampling(Int(sampling.step))
    case .imageDecoded:
      self = .imageDecoded
    case .secondPassImageEncoded:
      self = .secondPassImageEncoded
    case .secondPassSampling(let sampling):
      self = .secondPassSampling(Int(sampling.step))
    case .secondPassImageDecoded:
      self = .secondPassImageDecoded
    case .faceRestored:
      self = .faceRestored
    case .imageUpscaled:
      self = .imageUpscaled
    case .none:
      fatalError()
    }
  }
}

extension ImageGenerationSignpostProto {
  public init(from signpost: ImageGeneratorSignpost) {
    self = ImageGenerationSignpostProto.with {
      switch signpost {
      case .textEncoded:
        $0.signpost = .textEncoded(.init())
      case .imageEncoded, .controlsGenerated:
        $0.signpost = .imageEncoded(.init())
      case .sampling(let step):
        $0.signpost = .sampling(
          .with {
            $0.step = Int32(step)
          })
      case .imageDecoded:
        $0.signpost = .imageDecoded(.init())
      case .secondPassImageEncoded:
        $0.signpost = .secondPassImageEncoded(.init())
      case .secondPassSampling(let step):
        $0.signpost = .secondPassSampling(
          .with {
            $0.step = Int32(step)
          })
      case .secondPassImageDecoded:
        $0.signpost = .secondPassImageDecoded(.init())
      case .faceRestored:
        $0.signpost = .faceRestored(.init())
      case .imageUpscaled:
        $0.signpost = .imageUpscaled(.init())
      }
    }
  }
}

extension ImageGeneratorDeviceType {
  public init?(from type: DeviceType) {
    switch type {
    case .phone:
      self = .phone
    case .tablet:
      self = .tablet
    case .laptop:
      self = .laptop
    case .UNRECOGNIZED:
      return nil
    }
  }
}

// Note that all these delegate callbacks will happen on main thread.
public protocol ImageGenerationServiceDelegate: AnyObject {
  func didReceiveGenerationRequest(
    cancellation: @escaping () -> Void, signposts: Set<ImageGeneratorSignpost>, user: String,
    deviceType: ImageGeneratorDeviceType)
  func didUpdateGenerationProgress(
    signpost: ImageGeneratorSignpost, signposts: Set<ImageGeneratorSignpost>)
  func didCompleteGenerationResponse(success: Bool)
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public final class ImageGenerationServiceImpl: @unchecked Sendable,
  ImageGenerationService.SimpleServiceProtocol
{
  private let queue: DispatchQueue
  private let backupQueue: DispatchQueue
  private let imageGeneratorLock: DispatchQueue
  public var imageGenerator: ImageGenerator {
    get { imageGeneratorLock.sync { internalImageGenerator } }
    set { imageGeneratorLock.sync { internalImageGenerator = newValue } }
  }
  private var internalImageGenerator: ImageGenerator
  private let serverConfigurationRewriter: ServerConfigurationRewriter?
  public let serverIdentifier: UInt64
  public weak var delegate: ImageGenerationServiceDelegate? = nil
  private let logger = Logger(label: "com.draw-things.image-generation-service")
  public let usesBackupQueue = ManagedAtomic<Bool>(false)
  public let bridgeMode = ManagedAtomic<Bool>(false)
  public let responseCompression = ManagedAtomic<Bool>(false)
  public let enableModelBrowsing = ManagedAtomic<Bool>(false)
  public var sharedSecret: String? = nil

  // Configurable monitoring properties
  public struct CancellationMonitor {
    public var warningTimeout: TimeInterval
    public var crashTimeout: TimeInterval
    public init(warningTimeout: TimeInterval, crashTimeout: TimeInterval) {
      self.warningTimeout = warningTimeout
      self.crashTimeout = crashTimeout
    }
  }
  public let cancellationMonitor: CancellationMonitor?
  private let echoOnQueue: Bool

  public init(
    imageGenerator: ImageGenerator, queue: DispatchQueue, backupQueue: DispatchQueue,
    serverConfigurationRewriter: ServerConfigurationRewriter? = nil,
    cancellationMonitor: CancellationMonitor? = nil, echoOnQueue: Bool = false
  ) {
    self.internalImageGenerator = imageGenerator
    self.queue = queue
    self.backupQueue = backupQueue
    self.serverConfigurationRewriter = serverConfigurationRewriter
    self.cancellationMonitor = cancellationMonitor
    self.echoOnQueue = echoOnQueue
    imageGeneratorLock = DispatchQueue(label: "ImageGenerationServiceImpl.imageGeneratorLock")
    serverIdentifier = UInt64.random(in: UInt64.min...UInt64.max)
    logger.info("ImageGenerationServiceImpl init")
  }

  private func rpcError(code: RPCError.Code, message: String, cause: (any Error)? = nil)
    -> RPCError
  {
    RPCError(code: code, message: message, cause: cause)
  }

  private func writeResponseSynchronously(
    _ value: ImageGenerationResponse, to writer: RPCWriter<ImageGenerationResponse>
  ) throws {
    let semaphore = DispatchSemaphore(value: 0)
    let resultQueue = DispatchQueue(label: "ImageGenerationServiceImpl.writeResponse.result")
    var writeError: (any Error)?
    Task {
      do {
        try await writer.write(value)
      } catch {
        resultQueue.sync {
          writeError = error
        }
      }
      semaphore.signal()
    }
    semaphore.wait()
    if let writeError = resultQueue.sync(execute: { writeError }) {
      throw writeError
    }
  }

  private func requestedImageResponseFormat(from responseFormat: ResponseFormat)
    -> RequestedImageResponseFormat
  {
    switch responseFormat {
    case .unspecified, .UNRECOGNIZED:
      return .tensor
    case .png:
      return .png
    case .jpeg:
      return .jpeg
    }
  }

  private func requestedImageResponseFormats(from request: ImageGenerationRequest)
    -> (preview: RequestedImageResponseFormat, final: RequestedImageResponseFormat)
  {
    let baseFormat = requestedImageResponseFormat(from: request.responseFormat)
    let previewFormat: RequestedImageResponseFormat =
      request.previewResponseFormat == .unspecified
      ? baseFormat : requestedImageResponseFormat(from: request.previewResponseFormat)
    let finalFormat: RequestedImageResponseFormat =
      request.finalResponseFormat == .unspecified
      ? baseFormat : requestedImageResponseFormat(from: request.finalResponseFormat)
    return (preview: previewFormat, final: finalFormat)
  }

  private func responsePayloadType(from payloadType: EncodedImagePayloadType) -> ResponsePayloadType
  {
    switch payloadType {
    case .tensor:
      return .tensor
    case .png:
      return .png
    case .jpeg:
      return .jpeg
    }
  }

  private func shouldEmitPreview(signpost: ImageGeneratorSignpost, everyNSteps: UInt32) -> Bool {
    guard everyNSteps > 1 else { return true }
    let interval = Int(everyNSteps)
    switch signpost {
    case .sampling(let step), .secondPassSampling(let step):
      return step % interval == 0
    default:
      return false
    }
  }

  static func grpcCapabilities(enableModelBrowsing: Bool) -> String {
    let values: [(String, String)] = [
      ("protocol_version", "2"),
      ("legacy_response_format", "true"),
      ("split_response_formats", "true"),
      ("payload_type_fields", "true"),
      ("chunked_generated_images", "true"),
      ("preview_single_payload", "true"),
      ("default_response", "tensor"),
      ("model_browsing", enableModelBrowsing ? "true" : "false"),
    ]
    return values.map { "\($0.0)=\($0.1)" }.joined(separator: ";")
  }

  static func grpcTraceTags(
    requestID: String,
    eventType: String,
    payloadType: EncodedImagePayloadType? = nil,
    chunkIndex: Int? = nil,
    chunkTotal: Int? = nil,
    isTerminal: Bool? = nil
  ) -> [String] {
    var tags = [
      "request_id=\(requestID)",
      "event_type=\(eventType)",
    ]
    if let payloadType = payloadType {
      tags.append("payload_type=\(payloadType.rawValue)")
    }
    if let chunkIndex = chunkIndex {
      tags.append("chunk_index=\(chunkIndex)")
    }
    if let chunkTotal = chunkTotal {
      tags.append("chunk_total=\(chunkTotal)")
    }
    if let isTerminal = isTerminal {
      tags.append("is_terminal=\(isTerminal)")
    }
    return tags
  }

  private func validateGenerationRequest(
    configuration: GenerationConfiguration, modelOverrides: [ModelZoo.Specification]
  ) throws {
    guard configuration.steps > 0 else {
      throw rpcError(
        code: .invalidArgument, message: "Invalid configuration: steps must be > 0")
    }
    guard configuration.startWidth > 0, configuration.startHeight > 0 else {
      throw rpcError(
        code: .invalidArgument,
        message: "Invalid dimensions: startWidth/startHeight must be > 0")
    }
    if let model = configuration.model, !model.isEmpty {
      let hasModelMapping =
        ModelZoo.specificationForModel(model) != nil
        || ModelZoo.specificationForHumanReadableModel(model) != nil
        || modelOverrides.contains(where: { $0.file == model || $0.name == model })
      guard hasModelMapping else {
        throw rpcError(
          code: .invalidArgument, message: "Invalid configuration: missing model map for \(model)")
      }
    }
  }

  static private func cancellationMonitoring(
    successFlag: ManagedAtomic<Bool>, logger: Logger, cancellationMonitor: CancellationMonitor
  ) {
    let queue = DispatchQueue.global(qos: .userInitiated)

    // Schedule error log after configurable warning timeout
    queue.asyncAfter(deadline: .now() + cancellationMonitor.warningTimeout) {
      guard !successFlag.load(ordering: .acquiring) else { return }
      logger.error(
        "Image generation has been cancelled/disconnected for \(cancellationMonitor.warningTimeout) seconds and still not completed successfully"
      )

      // Schedule app exit after configurable exit timeout (total = warning + exit timeout)
      queue.asyncAfter(deadline: .now() + cancellationMonitor.crashTimeout) {
        guard !successFlag.load(ordering: .acquiring) else { return }
        logger.error(
          "Image generation has been cancelled/disconnected for \(cancellationMonitor.crashTimeout) seconds and still not completed successfully. Exiting application for restart."
        )
        exit(-1)
      }
    }
  }

  public func generateImage(
    request: ImageGenerationRequest,
    response: RPCWriter<ImageGenerationResponse>,
    context: ServerContext
  ) async throws {
    let requestID = UUID().uuidString
    logger.info("Received image processing request, begin. request_id=\(requestID)")

    if let sharedSecret = sharedSecret, !sharedSecret.isEmpty, request.sharedSecret != sharedSecret
    {
      throw rpcError(code: .unauthenticated, message: "Shared secret mismatch.")
    }

    let responseCompression = responseCompression.load(ordering: .acquiring)
    let runQueue = usesBackupQueue.load(ordering: .acquiring) ? backupQueue : queue
    let configuration = GenerationConfiguration.from(data: request.configuration)

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      runQueue.async { [weak self] in
        guard let self = self else {
          continuation.resume(
            throwing: RPCError(
              code: .internalError, message: "ImageGenerationServiceImpl deallocated."))
          return
        }

        do {
          if let serverConfigurationRewriter = self.serverConfigurationRewriter {
            var cancellation: ProtectedValue<(() -> Void)?> = ProtectedValue(nil)
            var rewriteResult: Result<GenerationConfiguration, any Error>?
            let rewriteWait = DispatchSemaphore(value: 0)

            serverConfigurationRewriter.newConfiguration(configuration: configuration) {
              bytesReceived, bytesExpected, index, total in
              let update = ImageGenerationResponse.with {
                $0.remoteDownload = RemoteDownloadResponse.with {
                  $0.bytesExpected = bytesExpected
                  $0.bytesReceived = bytesReceived
                  $0.item = Int32(index)
                  $0.itemsExpected = Int32(total)
                }
                $0.tags = Self.grpcTraceTags(
                  requestID: requestID,
                  eventType: "remote_download",
                  isTerminal: false
                )
              }
              try? self.writeResponseSynchronously(update, to: response)
            } cancellation: { cancellationBlock in
              cancellation.modify { $0 = cancellationBlock }
            } completion: { result in
              rewriteResult = result
              rewriteWait.signal()
            }

            rewriteWait.wait()
            cancellation.modify { $0 = nil }
            let rewrittenConfiguration = try rewriteResult!.get()

            try self.generateImage(
              configuration: rewrittenConfiguration,
              request: request,
              response: response,
              responseCompression: responseCompression,
              context: context,
              requestID: requestID
            )
          } else {
            try self.generateImage(
              configuration: configuration,
              request: request,
              response: response,
              responseCompression: responseCompression,
              context: context,
              requestID: requestID
            )
          }

          continuation.resume()
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private func generateImage(
    configuration: GenerationConfiguration,
    request: ImageGenerationRequest,
    response: RPCWriter<ImageGenerationResponse>,
    responseCompression: Bool,
    context: ServerContext,
    requestID: String
  ) throws {
    let cancelFlag = ManagedAtomic<Bool>(false)
    let successFlag = ManagedAtomic<Bool>(false)
    var cancellation: ProtectedValue<(() -> Void)?> = ProtectedValue(nil)
    let logger = logger
    let cancellationMonitor = cancellationMonitor
    let terminalEmitted = ManagedAtomic<Bool>(false)

    func emitTerminalEvent(_ status: String) {
      let once = terminalEmitted.compareExchange(
        expected: false, desired: true, ordering: .acquiringAndReleasing)
      guard once.exchanged else { return }
      let terminal = ImageGenerationResponse.with {
        $0.tags =
          Self.grpcTraceTags(
            requestID: requestID,
            eventType: "terminal",
            isTerminal: true
          ) + ["terminal_status=\(status)"]
      }
      try? writeResponseSynchronously(terminal, to: response)
    }

    func cancel() {
      cancelFlag.store(true, ordering: .releasing)
      cancellation.modify {
        $0?()
        $0 = nil
      }
      emitTerminalEvent("cancelled")
      if let cancellationMonitor = cancellationMonitor {
        Self.cancellationMonitoring(
          successFlag: successFlag, logger: logger, cancellationMonitor: cancellationMonitor)
      }
    }

    if context.cancellation.isCancelled {
      cancel()
    }

    try generateImage(
      configuration: configuration,
      request: request,
      response: response,
      responseCompression: responseCompression,
      cancelFlag: cancelFlag,
      successFlag: successFlag,
      cancellation: &cancellation,
      cancel: cancel,
      requestID: requestID,
      emitTerminalEvent: emitTerminalEvent,
      context: context
    )
  }

  private func generateImage(
    configuration: GenerationConfiguration,
    request: ImageGenerationRequest,
    response: RPCWriter<ImageGenerationResponse>,
    responseCompression: Bool,
    cancelFlag: ManagedAtomic<Bool>,
    successFlag: ManagedAtomic<Bool>,
    cancellation: inout ProtectedValue<(() -> Void)?>,
    cancel: @escaping () -> Void,
    requestID: String,
    emitTerminalEvent: @escaping (String) -> Void,
    context: ServerContext
  ) throws {
    func isCancelled() -> Bool {
      if context.cancellation.isCancelled {
        cancel()
      }
      return cancelFlag.load(ordering: .acquiring)
    }
    logger.info(
      "Received image processing request with configuration steps: \(configuration.steps), request_id=\(requestID)"
    )
    let override = request.override
    let jsonDecoder = JSONDecoder()
    jsonDecoder.keyDecodingStrategy = .convertFromSnakeCase
    let models =
      (try? jsonDecoder.decode(
        [FailableDecodable<ModelZoo.Specification>].self, from: override.models
      ).compactMap({ $0.value })) ?? []
    do {
      try validateGenerationRequest(configuration: configuration, modelOverrides: models)
    } catch {
      emitTerminalEvent("failed")
      throw error
    }
    let loras =
      (try? jsonDecoder.decode(
        [FailableDecodable<LoRAZoo.Specification>].self, from: override.loras
      ).compactMap({ $0.value })) ?? []
    let controlNets =
      (try? jsonDecoder.decode(
        [FailableDecodable<ControlNetZoo.Specification>].self, from: override.controlNets
      ).compactMap({ $0.value })) ?? []
    let textualInversions =
      (try? jsonDecoder.decode(
        [FailableDecodable<TextualInversionZoo.Specification>].self,
        from: override.textualInversions
      ).compactMap({ $0.value })) ?? []
    let upscalers =
      (try? jsonDecoder.decode(
        [FailableDecodable<UpscalerZoo.Specification>].self,
        from: override.upscalers
      ).compactMap({ $0.value })) ?? []
    ModelZoo.overrideMapping = Dictionary(models.map { ($0.file, $0) }) { v, _ in v }
    LoRAZoo.overrideMapping = Dictionary(loras.map { ($0.file, $0) }) { v, _ in v }
    ControlNetZoo.overrideMapping = Dictionary(controlNets.map { ($0.file, $0) }) { v, _ in v }
    TextualInversionZoo.overrideMapping = Dictionary(textualInversions.map { ($0.file, $0) }) {
      v, _ in v
    }
    UpscalerZoo.overrideMapping = Dictionary(upscalers.map { ($0.file, $0) }) { v, _ in v }
    defer {
      ModelZoo.overrideMapping = [:]
      LoRAZoo.overrideMapping = [:]
      ControlNetZoo.overrideMapping = [:]
      TextualInversionZoo.overrideMapping = [:]
      UpscalerZoo.overrideMapping = [:]
    }
    let chunked = request.chunked
    let requestedFormats = requestedImageResponseFormats(from: request)
    let previewEveryNSteps = request.previewEveryNsteps
    logger.info(
      "Requested response formats: preview=\(String(describing: requestedFormats.preview)), final=\(String(describing: requestedFormats.final)), previewEveryNSteps=\(previewEveryNSteps)"
    )

    let progressUpdateHandler:
      (ImageGeneratorSignpost, Set<ImageGeneratorSignpost>, Tensor<FloatType>?) -> Bool = {
        [weak self] signpost, signposts, previewTensor in
        guard let self = self else { return false }

        guard !isCancelled() else {
          self.logger.info(
            "cancelled image generation request_id=\(requestID)"
          )
          return false
        }

        let update = ImageGenerationResponse.with {
          $0.currentSignpost = ImageGenerationSignpostProto(from: signpost)
          $0.signposts = Array(
            signposts.map { signpost in
              ImageGenerationSignpostProto(from: signpost)
            })

          if let previewTensor = previewTensor,
            self.shouldEmitPreview(signpost: signpost, everyNSteps: previewEveryNSteps),
            let encodedPreview = ImageResponseEncoder.encodePreviewImage(
              from: previewTensor, responseFormat: requestedFormats.preview,
              responseCompression: responseCompression)
          {
            $0.previewImage = encodedPreview.payload
            $0.previewPayloadType = self.responsePayloadType(from: encodedPreview.payloadType)
            $0.tags = Self.grpcTraceTags(
              requestID: requestID,
              eventType: "progress_preview",
              payloadType: encodedPreview.payloadType,
              isTerminal: false
            )
          } else {
            $0.tags = Self.grpcTraceTags(
              requestID: requestID,
              eventType: "progress",
              isTerminal: false
            )
          }
        }

        do {
          try self.writeResponseSynchronously(update, to: response)
        } catch {
          self.logger.error("Failed to write progress update: \(error)")
          cancel()
          return false
        }
        if let delegate = self.delegate {
          DispatchQueue.main.async {
            delegate.didUpdateGenerationProgress(signpost: signpost, signposts: signposts)
          }
        }
        return true
      }

    var contents = [Data: Data]()
    for content in request.contents {
      let hash = Data(SHA256.hash(data: content))
      contents[hash] = content
    }

    func unwrapData(_ data: Data) -> Data {
      guard data.count == 32 else { return data }
      // If it is 32-byte, that is sha256, unwrap.
      return contents[data] ?? Data()
    }
    // Additional conversion if needed.
    let image: Tensor<FloatType>? =
      request.hasImage
      ? Tensor<FloatType>(data: unwrapData(request.image), using: [.zip, .fpzip]).map {
        Tensor<FloatType>(from: $0)
      } : nil
    let mask: Tensor<UInt8>? =
      request.hasMask
      ? Tensor<UInt8>(data: unwrapData(request.mask), using: [.zip, .fpzip]) : nil

    var hints = [(ControlHintType, [(AnyTensor, Float)])]()
    for hintProto in request.hints {
      if let hintType = ControlHintType(rawValue: hintProto.hintType) {
        logger.info("Created ControlHintType: \(hintType)")
        if hintType == .scribble {
          if let tensorData = hintProto.tensors.first?.tensor,
            let score = hintProto.tensors.first?.weight,
            let hintTensor = Tensor<UInt8>(data: unwrapData(tensorData), using: [.zip, .fpzip])
          {
            hints.append((hintType, [(hintTensor, score)]))
          }
        } else {
          let tensors = hintProto.tensors.compactMap { tensorAndWeight in
            if let tensor = Tensor<FloatType>(
              data: unwrapData(tensorAndWeight.tensor), using: [.zip, .fpzip])
            {
              // Additional conversion, if needed.
              return (Tensor<FloatType>(from: tensor), tensorAndWeight.weight)
            }
            return nil
          }
          hints.append((hintType, tensors))
        }

      } else {
        logger.error("Invalid ControlHintType \(hintProto.hintType)")
      }
    }

    let signposts = ImageGeneratorUtils.expectedSignposts(
      image != nil, mask: mask != nil, text: request.prompt, negativeText: request.negativePrompt,
      configuration: configuration, version: ModelZoo.versionForModel(configuration.model ?? ""),
      memorizedBy: [])
    if let delegate = self.delegate {
      let user = request.user
      let deviceType = ImageGeneratorDeviceType(from: request.device) ?? .laptop
      DispatchQueue.main.async {
        delegate.didReceiveGenerationRequest(
          cancellation: cancel, signposts: signposts, user: user, deviceType: deviceType)
      }
    }
    do {
      let trace = ImageGeneratorTrace(fromBridge: true)
      // Note that the imageGenerator must be local image generator, otherwise it throws.
      let (images, audio, scaleFactor) = try self.imageGenerator.generate(
        trace: trace, image: image, scaleFactor: Int(request.scaleFactor), mask: mask, hints: hints,
        text: request.prompt, negativeText: request.negativePrompt, configuration: configuration,
        fileMapping: [:],
        keywords: request.keywords,
        cancellation: { cancellationBlock in
          cancellation.modify {
            $0 = cancellationBlock
          }
        }, feedback: progressUpdateHandler)

      successFlag.store(true, ordering: .releasing)

      let encodedImages = ImageResponseEncoder.encodeImages(
        from: images, responseFormat: requestedFormats.final,
        responseCompression: responseCompression)
      let imageDatas = encodedImages.payloads
      let finalPayloadType = responsePayloadType(from: encodedImages.payloadType)
      let audioCodec: DynamicGraph.Store.Codec = responseCompression ? [.zip, .fpzip] : []
      let audioData = audio?.compactMap { $0.data(using: audioCodec) }
      logger.info("Image processed")
      let totalBytes = imageDatas.reduce(0) { partialResult, imageData in
        return partialResult + imageData.count
      }
      logger.info(
        "Image response payloadType=\(encodedImages.payloadType.rawValue), count=\(imageDatas.count), bytes=\(totalBytes)"
      )
      if totalBytes > 0 {
        let projectionResponse = ImageGenerationResponse.with {
          $0.downloadSize = Int64(totalBytes)
          $0.tags = Self.grpcTraceTags(
            requestID: requestID,
            eventType: "download_projection",
            isTerminal: false
          )
        }
        try writeResponseSynchronously(projectionResponse, to: response)
      }
      if imageDatas.isEmpty {
        let finalResponse = ImageGenerationResponse.with {
          if isCancelled() {
            logger.info("Image processed cancelled, generated images return nil")
          } else {
            let configurationDictionary: [String: Any]
            if let jsonData = try? JSONEncoder().encode(
              JSGenerationConfiguration(configuration: configuration))
            {
              configurationDictionary =
                (try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]) ?? [:]
            } else {
              configurationDictionary = [:]
            }
            logger.error(
              "Image processed failed, failed configuration:\(configurationDictionary)")
          }
          $0.scaleFactor = Int32(scaleFactor)
          $0.chunkState = .lastChunk
          $0.tags = Self.grpcTraceTags(
            requestID: requestID,
            eventType: "final_empty",
            isTerminal: false
          )
        }
        try writeResponseSynchronously(finalResponse, to: response)
      } else {
        let chunked = chunked && totalBytes > 4 * 1024 * 1024  // If total bytes is less than 4MiB, send them in one batch. Otherwise, chunk them up.
        logger.info("Image processed successfully, should send in chunks? \(chunked)")
        if chunked {
          for imageData in imageDatas {
            let chunks = ImageResponseEncoder.chunkedPayloads(
              imageData, maxChunkSize: 4 * 1024 * 1024)
            for (index, chunk) in chunks.enumerated() {
              let finalResponse = ImageGenerationResponse.with {
                $0.generatedImages = [chunk]
                $0.scaleFactor = Int32(scaleFactor)
                $0.chunkState = index == chunks.count - 1 ? .lastChunk : .moreChunks
                $0.finalPayloadType = finalPayloadType
                $0.tags = Self.grpcTraceTags(
                  requestID: requestID,
                  eventType: "final_image",
                  payloadType: encodedImages.payloadType,
                  chunkIndex: index,
                  chunkTotal: chunks.count,
                  isTerminal: false
                )
              }
              try writeResponseSynchronously(finalResponse, to: response)
            }
          }
        } else {
          for imageData in imageDatas {
            let finalResponse = ImageGenerationResponse.with {
              $0.generatedImages = [imageData]
              $0.scaleFactor = Int32(scaleFactor)
              $0.chunkState = .lastChunk
              $0.finalPayloadType = finalPayloadType
              $0.tags = Self.grpcTraceTags(
                requestID: requestID,
                eventType: "final_image",
                payloadType: encodedImages.payloadType,
                chunkIndex: 0,
                chunkTotal: 1,
                isTerminal: false
              )
            }
            try writeResponseSynchronously(finalResponse, to: response)
          }
        }
      }
      if let audioData = audioData {
        let chunked = chunked && totalBytes > 4 * 1024 * 1024  // If total bytes is less than 4MiB, send them in one batch. Otherwise, chunk them up.
        logger.info("Audio processed successfully, should send in chunks? \(chunked)")
        if chunked {
          for audio in audioData {
            let dataSize = audio.count
            if dataSize <= 4 * 1024 * 1024 {
              let finalResponse = ImageGenerationResponse.with {
                $0.generatedAudio = [audio]
                $0.chunkState = .lastChunk
                $0.tags = Self.grpcTraceTags(
                  requestID: requestID,
                  eventType: "final_audio",
                  chunkIndex: 0,
                  chunkTotal: 1,
                  isTerminal: false
                )
              }
              try writeResponseSynchronously(finalResponse, to: response)
            } else {
              for j in stride(from: 0, to: dataSize, by: 4 * 1024 * 1024) {
                let chunkSize = min(4 * 1024 * 1024, dataSize - j)
                let subdata = audio[j..<(j + chunkSize)]
                let finalResponse = ImageGenerationResponse.with {
                  $0.generatedAudio = [subdata]
                  if j + chunkSize == dataSize {
                    $0.chunkState = .lastChunk
                  } else {
                    $0.chunkState = .moreChunks
                  }
                  $0.tags = Self.grpcTraceTags(
                    requestID: requestID,
                    eventType: "final_audio",
                    chunkIndex: j / (4 * 1024 * 1024),
                    chunkTotal: (dataSize + 4 * 1024 * 1024 - 1) / (4 * 1024 * 1024),
                    isTerminal: false
                  )
                }
                try writeResponseSynchronously(finalResponse, to: response)
              }
            }
          }
        } else {
          for audio in audioData {
            let finalResponse = ImageGenerationResponse.with {
              $0.generatedAudio = [audio]
              $0.chunkState = .lastChunk
              $0.tags = Self.grpcTraceTags(
                requestID: requestID,
                eventType: "final_audio",
                chunkIndex: 0,
                chunkTotal: 1,
                isTerminal: false
              )
            }
            try writeResponseSynchronously(finalResponse, to: response)
          }
        }
      }
      let success = imageDatas.isEmpty ? false : true
      emitTerminalEvent(success ? "completed" : (isCancelled() ? "cancelled" : "failed"))
      if let delegate = delegate {
        DispatchQueue.main.async {
          delegate.didCompleteGenerationResponse(success: success)
        }
      }
    } catch (let error) {
      emitTerminalEvent(isCancelled() ? "cancelled" : "failed")
      if let delegate = delegate {
        DispatchQueue.main.async {
          delegate.didCompleteGenerationResponse(success: false)
        }
      }
      throw error
    }
  }

  public func filesExist(request: FileListRequest, context: ServerContext) async throws
    -> FileExistenceResponse
  {
    logger.info("Received request for files exist: \(request.files)")
    if let sharedSecret = sharedSecret, !sharedSecret.isEmpty {
      guard request.sharedSecret == sharedSecret else {
        throw rpcError(code: .unauthenticated, message: "Shared secret mismatch.")
      }
    }
    var files = [String]()
    var existences = [Bool]()
    var hashes = [Data]()
    let needsToComputeHash = Set<String>(request.filesWithHash)
    for file in request.files {
      let existence = ModelZoo.isModelDownloaded(file)
      files.append(file)
      existences.append(existence)
      if needsToComputeHash.contains(file) {
        let filePath = ModelZoo.filePathForModelDownloaded(file)
        if let fileData = try? Data(
          contentsOf: URL(fileURLWithPath: filePath), options: .mappedIfSafe)
        {
          let computedHash = Data(SHA256.hash(data: fileData))
          hashes.append(computedHash)
        } else {
          hashes.append(Data())
        }
      } else {
        hashes.append(Data())
      }
    }
    let response = FileExistenceResponse.with {
      $0.files = files
      $0.existences = existences
      $0.hashes = hashes
    }
    return response
  }

  public func pubkey(request: PubkeyRequest, context: ServerContext) async throws -> PubkeyResponse
  {
    PubkeyResponse.with { _ in }
  }

  public func hours(request: HoursRequest, context: ServerContext) async throws -> HoursResponse {
    HoursResponse.with { _ in }
  }

  public func echo(request: GRPCImageServiceModels.EchoRequest, context: ServerContext)
    async throws -> GRPCImageServiceModels.EchoReply
  {
    let enableModelBrowsing = enableModelBrowsing.load(ordering: .acquiring)
    let response = EchoReply.with {
      logger.info("Received echo from: \(request.name), enableModelBrowsing:\(enableModelBrowsing)")
      if let sharedSecret = sharedSecret, !sharedSecret.isEmpty {
        guard request.sharedSecret == sharedSecret else {
          // Mismatch on shared secret.
          $0.sharedSecretMissing = true
          return
        }
      }
      $0.serverIdentifier = serverIdentifier
      $0.sharedSecretMissing = false
      $0.message =
        "HELLO \(request.name)\nCAPABILITIES \(Self.grpcCapabilities(enableModelBrowsing: enableModelBrowsing))"
      if enableModelBrowsing {
        // Looking for ckpt files.
        let internalFilePath = ModelZoo.internalFilePathForModelDownloaded("")
        let fileManager = FileManager.default
        var fileUrls = [URL]()
        if let urls = try? fileManager.contentsOfDirectory(
          at: URL(fileURLWithPath: internalFilePath), includingPropertiesForKeys: [.fileSizeKey],
          options: [.skipsHiddenFiles, .skipsPackageDescendants, .skipsSubdirectoryDescendants])
        {
          fileUrls.append(contentsOf: urls)
        }
        if let externalUrl = ModelZoo.externalUrls.first,
          let urls = try? fileManager.contentsOfDirectory(
            at: externalUrl, includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants, .skipsSubdirectoryDescendants])
        {
          fileUrls.append(contentsOf: urls)
        }
        // Check if the file ends with ckpt. If it is, this is a file we need to fill.
        $0.files = fileUrls.compactMap {
          guard let values = try? $0.resourceValues(forKeys: [.fileSizeKey]) else { return nil }
          guard let fileSize = values.fileSize, fileSize > 0 else { return nil }
          let file = $0.lastPathComponent
          guard file.lowercased().hasSuffix(".ckpt") else { return nil }
          return file
        }
        // Load all specifications that is available locally into override JSON payload.
        let models = ModelZoo.availableSpecifications.filter {
          return ModelZoo.isModelDownloaded($0)
        }
        let loras = LoRAZoo.availableSpecifications.filter {
          return LoRAZoo.isModelDownloaded($0)
        }
        let controlNets = ControlNetZoo.availableSpecifications.filter {
          return ControlNetZoo.isModelDownloaded($0)
        }
        let textualInversions = TextualInversionZoo.availableSpecifications.filter {
          return TextualInversionZoo.isModelDownloaded($0.file)
        }
        let upscalers = UpscalerZoo.availableSpecifications.filter {
          return UpscalerZoo.isModelDownloaded($0.file)
        }
        $0.override = MetadataOverride.with {
          let jsonEncoder = JSONEncoder()
          jsonEncoder.keyEncodingStrategy = .convertToSnakeCase
          $0.models = (try? jsonEncoder.encode(models)) ?? Data()
          $0.loras = (try? jsonEncoder.encode(loras)) ?? Data()
          $0.controlNets = (try? jsonEncoder.encode(controlNets)) ?? Data()
          $0.textualInversions = (try? jsonEncoder.encode(textualInversions)) ?? Data()
          $0.upscalers = (try? jsonEncoder.encode(upscalers)) ?? Data()
        }
      }
    }
    if echoOnQueue {
      return try await withCheckedThrowingContinuation { continuation in
        queue.async {
          continuation.resume(returning: response)
        }
      }
    } else {
      return response
    }
  }

  public func uploadFile(
    request: RPCAsyncSequence<FileUploadRequest, any Error>,
    response: RPCWriter<UploadResponse>,
    context _: ServerContext
  ) async throws {
    logger.info("Received uploadFile request")

    var fileHandle: FileHandle?
    var totalBytesReceived: Int64 = 0
    var metadata:
      (file: String, expectedFileSize: Int64, expectedHash: Data, temporaryPath: String)?

    do {
      for try await uploadRequest in request {
        if let sharedSecret = sharedSecret, !sharedSecret.isEmpty,
          uploadRequest.sharedSecret != sharedSecret
        {
          throw rpcError(code: .unauthenticated, message: "Shared secret mismatch.")
        }

        switch uploadRequest.request {
        case .initRequest(let initRequest):
          let temporaryPath = ModelZoo.filePathForModelDownloaded(initRequest.filename + ".part")
          metadata = (
            file: initRequest.filename, expectedFileSize: initRequest.totalSize,
            expectedHash: initRequest.sha256, temporaryPath: temporaryPath
          )
          logger.info("Init upload for metadata: \(String(describing: metadata))")
          let _ = FileManager.default.createFile(atPath: temporaryPath, contents: nil)
          fileHandle = FileHandle(forWritingAtPath: temporaryPath)
          guard fileHandle != nil else {
            throw rpcError(code: .internalError, message: "Failed to create file handle.")
          }

          var initResponse = UploadResponse()
          initResponse.chunkUploadSuccess = true
          initResponse.filename = initRequest.filename
          initResponse.message = "File upload initialized successfully"
          try await response.write(initResponse)

        case .chunk(let chunk):
          guard let fileHandle else {
            throw rpcError(code: .internalError, message: "Failed to create file handle.")
          }

          logger.info(
            "Received chunk \(chunk.filename) chunk.offset:\(chunk.offset) totalBytesReceived:\(totalBytesReceived)"
          )

          guard chunk.offset == totalBytesReceived else {
            throw rpcError(code: .dataLoss, message: "Received chunk with unexpected offset.")
          }

          try fileHandle.write(contentsOf: chunk.content)
          totalBytesReceived += Int64(chunk.content.count)

          var chunkResponse = UploadResponse()
          chunkResponse.chunkUploadSuccess = true
          chunkResponse.filename = chunk.filename
          chunkResponse.receivedOffset = totalBytesReceived
          chunkResponse.message = "Chunk uploaded successfully"
          try await response.write(chunkResponse)

        case .none:
          logger.info("Received empty upload request")
        }
      }

      guard let metadata else {
        throw rpcError(code: .internalError, message: "Missing file metadata.")
      }

      guard let fileHandle else {
        throw rpcError(code: .internalError, message: "Missing file handle.")
      }

      try fileHandle.close()
      logger.info("uploaded filename: \(metadata.file).part")

      guard totalBytesReceived == metadata.expectedFileSize else {
        throw rpcError(
          code: .invalidArgument,
          message:
            "Uploaded size mismatch totalBytesReceived: \(totalBytesReceived) expectedFileSize: \(metadata.expectedFileSize)"
        )
      }

      guard
        self.validateUploadedFile(
          atPath: metadata.temporaryPath,
          filename: metadata.file,
          expectedHash: metadata.expectedHash
        )
      else {
        try? FileManager.default.removeItem(atPath: metadata.temporaryPath)
        throw rpcError(code: .dataLoss, message: "File validation failed.")
      }

      try? FileManager.default.removeItem(
        atPath: ModelZoo.filePathForModelDownloaded(metadata.file))
      try? FileManager.default.moveItem(
        atPath: metadata.temporaryPath,
        toPath: ModelZoo.filePathForModelDownloaded(metadata.file))
      logger.info("File uploaded successfully")

    } catch {
      if let fileHandle {
        try? fileHandle.close()
      }
      if let metadata {
        logger.info("Cleaning up partial file: \(metadata.temporaryPath)")
        try? FileManager.default.removeItem(atPath: metadata.temporaryPath)
      }
      throw error
    }
  }

  private func validateUploadedFile(atPath path: String, filename: String, expectedHash: Data)
    -> Bool
  {
    do {
      let fileData = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
      let computedHash = Data(SHA256.hash(data: fileData))
      self.logger.info("expectedHash: \(expectedHash.map { String(format: "%02x", $0) }.joined())")
      self.logger.info("computedHash: \(computedHash.map { String(format: "%02x", $0) }.joined())")
      if computedHash != expectedHash {
        logger.error(
          "File hash mismatch for \(filename) expectedHash \(computedHash) expectedHash \(expectedHash)"
        )
        return false
      }
    } catch {
      logger.error("Failed to validate file type: \(error.localizedDescription)")
    }

    return true
  }
}
