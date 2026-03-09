import Crypto
import DataModels
import Diffusion
import Foundation
import GRPCCore
import GRPCImageServiceModels
import GRPCServer
import ImageGenerator
import Logging
import ModelZoo
import NNC
import OrderedCollections

#if canImport(CoreGraphics) && canImport(ImageIO)
  import CoreGraphics
  import ImageIO
#endif

private func tensorFromEncodedImageData(_ data: Data) -> Tensor<FloatType>? {
  #if canImport(CoreGraphics) && canImport(ImageIO)
    guard
      let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
      let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
    else {
      return nil
    }
    guard
      let bitmapContext = CGContext(
        data: nil, width: cgImage.width, height: cgImage.height, bitsPerComponent: 8,
        bytesPerRow: cgImage.width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo.byteOrderDefault.rawValue
          | CGImageAlphaInfo.premultipliedLast.rawValue, releaseCallback: nil, releaseInfo: nil)
    else {
      return nil
    }
    bitmapContext.draw(
      cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
    guard let data = bitmapContext.data else { return nil }
    let bytes = data.assumingMemoryBound(to: UInt8.self)
    let width = bitmapContext.width
    let height = bitmapContext.height
    let bytesPerRow = bitmapContext.bytesPerRow
    var tensor = Tensor<FloatType>(.CPU, .NHWC(1, height, width, 3))
    tensor.withUnsafeMutableBytes { rawBuffer in
      guard let fp = rawBuffer.baseAddress?.assumingMemoryBound(to: FloatType.self) else { return }
      for y in 0..<height {
        let row = y * bytesPerRow
        for x in 0..<width {
          let src = row + x * 4
          let dst = (y * width + x) * 3
          fp[dst] = FloatType((Float(bytes[src]) / 127.5) - 1)
          fp[dst + 1] = FloatType((Float(bytes[src + 1]) / 127.5) - 1)
          fp[dst + 2] = FloatType((Float(bytes[src + 2]) / 127.5) - 1)
        }
      }
    }
    return tensor
  #else
    return nil
  #endif
}

public enum RemoteImageGeneratorError: Error {
  case notConnected
  case failedWithStatus(RPCError)
  case failedWithError(Error)
}

extension DeviceType {
  init(from type: ImageGeneratorDeviceType) {
    switch type {
    case .phone:
      self = .phone
    case .tablet:
      self = .tablet
    case .laptop:
      self = .laptop
    }
  }
}

public struct RemoteImageGenerator: ImageGenerator {
  private let logger = Logger(label: "com.draw-things.remote-image-generator")
  public let client: ImageGenerationClientWrapper
  public let serverIdentifier: UInt64
  public let name: String
  public let deviceType: ImageGeneratorDeviceType
  private var authenticationHandler:
    ((Bool, Data, GenerationConfiguration, Bool, Int, (@escaping () -> Void) -> Void) -> String?)?
  private var requestExceedLimitHandler: (() -> Void)?

  public init(
    name: String, deviceType: ImageGeneratorDeviceType, client: ImageGenerationClientWrapper,
    serverIdentifier: UInt64,
    authenticationHandler: (
      (Bool, Data, GenerationConfiguration, Bool, Int, (@escaping () -> Void) -> Void) -> String?
    )?,
    requestExceedLimitHandler: (() -> Void)?
  ) {
    self.name = name
    self.deviceType = deviceType
    self.client = client
    self.serverIdentifier = serverIdentifier
    self.authenticationHandler = authenticationHandler
    self.requestExceedLimitHandler = requestExceedLimitHandler
  }

  public struct TransferDataCallback {
    public var beginUpload: (Int) -> Void
    public var beginDownload: (Int) -> Void
    public var remoteDownloads: (Int64, Int64, Int, Int) -> Void
    public init(
      beginUpload: @escaping (Int) -> Void, beginDownload: @escaping (Int) -> Void,
      remoteDownloads: @escaping (Int64, Int64, Int, Int) -> Void
    ) {
      self.beginUpload = beginUpload
      self.beginDownload = beginDownload
      self.remoteDownloads = remoteDownloads
    }
  }

  public var transferDataCallback: TransferDataCallback? = nil

  public func generate(
    trace: ImageGeneratorTrace,
    image: Tensor<FloatType>?, scaleFactor: Int, mask: Tensor<UInt8>?,
    hints: [(ControlHintType, [(AnyTensor, Float)])],
    text: String, negativeText: String, configuration: GenerationConfiguration,
    fileMapping: [String: String], keywords: [String], cancellation: (@escaping () -> Void) -> Void,
    feedback: @escaping (ImageGeneratorSignpost, Set<ImageGeneratorSignpost>, Tensor<FloatType>?)
      -> Bool
  ) throws -> ([Tensor<FloatType>]?, [Tensor<Float>]?, Int) {
    let sharedSecret = client.sharedSecret
    guard let client = client.client else {
      throw RemoteImageGeneratorError.notConnected
    }
    var metadataOverride = ImageGeneratorUtils.metadataOverride(configuration)
    var configuration = configuration
    // Replacing local LoRA to the LoRA name that is mapped.
    if !configuration.loras.isEmpty, !fileMapping.isEmpty {
      var configurationBuilder = GenerationConfigurationBuilder(from: configuration)
      for i in 0..<metadataOverride.loras.count {
        if let value = fileMapping[metadataOverride.loras[i].file] {
          metadataOverride.loras[i].file = String(value.split(separator: "_")[0])  // Map to sha256 only.
        }
      }
      for i in 0..<configurationBuilder.loras.count {
        if let value = (configurationBuilder.loras[i].file.flatMap { fileMapping[$0] }) {
          configurationBuilder.loras[i].file = value  // Still contains the full name.
        }
      }
      configuration = configurationBuilder.build()
    }
    var overrideProto = MetadataOverride()
    let jsonEncoder = JSONEncoder()
    jsonEncoder.keyEncodingStrategy = .convertToSnakeCase
    jsonEncoder.outputFormatting = [.sortedKeys]
    overrideProto.models = (try? jsonEncoder.encode(metadataOverride.models)) ?? Data()
    overrideProto.loras = (try? jsonEncoder.encode(metadataOverride.loras)) ?? Data()
    overrideProto.controlNets = (try? jsonEncoder.encode(metadataOverride.controlNets)) ?? Data()
    overrideProto.textualInversions =
      (try? jsonEncoder.encode(
        keywords.compactMap {
          TextualInversionZoo.specificationForModel(
            TextualInversionZoo.modelFromKeyword($0, potentials: []) ?? "")
        })) ?? Data()
    overrideProto.upscalers = (try? jsonEncoder.encode(metadataOverride.upscalers)) ?? Data()

    var request = ImageGenerationRequest()
    request.configuration = configuration.toData()
    request.prompt = text
    request.negativePrompt = negativeText
    request.scaleFactor = Int32(scaleFactor)
    request.override = overrideProto
    request.keywords = keywords
    request.user = name
    request.device = DeviceType(from: deviceType)
    request.chunked = true
    request.responseFormat = .responseFormatPng
    request.previewResponseFormat = .responseFormatPng
    request.finalResponseFormat = .responseFormatPng
    if let sharedSecret = sharedSecret {
      request.sharedSecret = sharedSecret
    }
    var contents = OrderedDictionary<Data, Data>()

    if let image = image {
      let data = image.data(using: [.zip, .fpzip])
      let hash = Data(SHA256.hash(data: data))
      request.image = hash
      contents[hash] = data
    }

    if let mask = mask {
      let data = mask.data(using: [.zip, .fpzip])
      let hash = Data(SHA256.hash(data: data))
      request.mask = hash
      contents[hash] = data
    }

    // TODO: can check if hints is referenced from configuration to decide whether to send it or not.
    for (hintType, hintTensors) in hints {
      if !hintTensors.isEmpty {
        request.hints.append(
          HintProto.with {
            $0.hintType = hintType.rawValue
            $0.tensors = hintTensors.map { tensor, weight in
              return TensorAndWeight.with {
                let data = ImageGeneratorUtils.convertTensorToData(
                  tensor: tensor, using: [.zip, .fpzip])
                let hash = Data(SHA256.hash(data: data))
                $0.tensor = hash
                contents[hash] = data
                $0.weight = weight
              }
            }
          })
      }
    }
    // If this is txt2img, there is not controlnet, no modifier, not inpainting.
    let modifier: SamplerModifier =
      configuration.model.map {
        ImageGeneratorUtils.modifierForModel($0, LoRAs: configuration.loras.compactMap(\.file))
      } ?? .none
    let isInpainting = ImageGeneratorUtils.isInpainting(
      for: mask, configuration: configuration, memorizedBy: [])
    let version = configuration.model.map { ModelZoo.versionForModel($0) } ?? .v1
    if configuration.strength == 1 && configuration.controls.isEmpty && modifier == .none
      && !isInpainting && version != .svdI2v
    {
      // Don't need to send any data. This is a small optimization and this logic can be fragile.
      contents.removeAll()
    }

    request.contents = []
    let encodedBlob = try? request.serializedData()
    request.contents = Array(contents.values)
    let totalBytes =
      (encodedBlob?.count ?? 0)
      + request.contents.reduce(0) { partialResult, content in
        return partialResult + content.count
      }
    transferDataCallback?.beginUpload(totalBytes)
    let bearer: String?
    if let encodedBlob = encodedBlob, !encodedBlob.isEmpty,
      let authenticationHandler = authenticationHandler
    {
      let hasImage = image != nil
      let shuffleCount: Int = hints.reduce(0) {
        guard $1.0 == .shuffle else { return $0 }
        let shuffleCount: Int = $1.1.reduce(0) {
          $0 + ($1.1 > 0 ? 1 : 0)
        }
        return $0 + shuffleCount
      }
      bearer = authenticationHandler(
        trace.fromBridge,
        encodedBlob, configuration, hasImage, shuffleCount, cancellation)
    } else {
      bearer = nil
    }

    // Send the request
    // handler is running on event group thread
    let logger = logger
    var lastChunk = Data()
    var tensors = [Tensor<FloatType>]()
    var lastAudioChunk = Data()
    var audios = [Tensor<Float>]()
    var scaleFactor: Int = 1
    let cancellationQueue = DispatchQueue(label: "RemoteImageGenerator.cancellation")
    var shouldCancel = false
    var metadata: Metadata = [:]
    if let bearer = bearer {
      metadata["authorization"] = "bearer \(bearer)"
    }

    let callOptions = CallOptions.defaults
    let completionSemaphore = DispatchSemaphore(value: 0)
    let resultQueue = DispatchQueue(label: "RemoteImageGenerator.generate.result")
    var completionError: RemoteImageGeneratorError? = nil

    cancellation {
      cancellationQueue.sync {
        shouldCancel = true
      }
    }

    Task {
      defer { completionSemaphore.signal() }
      do {
        try await client.generateImage(
          request,
          metadata: metadata,
          options: callOptions
        ) { streamingResponse in
          for try await response in streamingResponse.messages {
            let isCancelled = cancellationQueue.sync { shouldCancel }
            if isCancelled {
              throw CancellationError()
            }
            if response.hasRemoteDownload {
              transferDataCallback?.remoteDownloads(
                response.remoteDownload.bytesReceived, response.remoteDownload.bytesExpected,
                Int(response.remoteDownload.item), Int(response.remoteDownload.itemsExpected))
            }
            if !response.generatedImages.isEmpty {
              let imageTensors: [Tensor<FloatType>]
              switch response.chunkState {
              case .lastChunk:
                imageTensors = response.generatedImages.enumerated().compactMap {
                  i, generatedImageData in
                  let imageData: Data
                  if i == 0, !lastChunk.isEmpty {
                    imageData = lastChunk + generatedImageData
                  } else {
                    imageData = generatedImageData
                  }
                  switch response.finalPayloadType {
                  case .responsePayloadTypeTensor:
                    if let image = Tensor<FloatType>(data: imageData, using: [.zip, .fpzip]) {
                      return Tensor<FloatType>(from: image)
                    }
                  case .responsePayloadTypePng, .responsePayloadTypeJpeg:
                    if let image = tensorFromEncodedImageData(imageData) {
                      return image
                    }
                  case .responsePayloadTypeUnspecified, .UNRECOGNIZED:
                    if let image = Tensor<FloatType>(data: imageData, using: [.zip, .fpzip]) {
                      return Tensor<FloatType>(from: image)
                    } else if let image = tensorFromEncodedImageData(imageData) {
                      return image
                    }
                  }
                  return nil
                }
                lastChunk = Data()
              case .moreChunks:
                if let first = response.generatedImages.first {
                  lastChunk += first
                }
                imageTensors = []
              case .UNRECOGNIZED(_):
                imageTensors = []
              }
              logger.info("Received generated image data")
              tensors.append(contentsOf: imageTensors)
            }
            if !response.generatedAudio.isEmpty {
              let audioTensors: [Tensor<Float>]
              switch response.chunkState {
              case .lastChunk:
                audioTensors = response.generatedAudio.enumerated().compactMap {
                  i, generatedAudioData in
                  let audioData: Data
                  if i == 0, !lastAudioChunk.isEmpty {
                    audioData = lastAudioChunk + generatedAudioData
                  } else {
                    audioData = generatedAudioData
                  }
                  if let audio = Tensor<Float>(data: audioData, using: [.zip, .fpzip]) {
                    return Tensor<Float>(from: audio)
                  } else {
                    return nil
                  }
                }
                lastAudioChunk = Data()
              case .moreChunks:
                if let first = response.generatedAudio.first {
                  lastAudioChunk += first
                }
                audioTensors = []
              case .UNRECOGNIZED(_):
                audioTensors = []
              }
              logger.info("Received generated audio data")
              audios.append(contentsOf: audioTensors)
            }
            if response.hasDownloadSize && response.downloadSize > 0 {
              transferDataCallback?.beginDownload(Int(response.downloadSize))
            }
            if response.hasCurrentSignpost {
              let currentSignpost = ImageGeneratorSignpost(
                from: response.currentSignpost)
              let signpostsSet = Set(
                response.signposts.map { signpostProto in
                  ImageGeneratorSignpost(from: signpostProto)
                })
              var previewTensor: Tensor<FloatType>? = nil
              if response.hasPreviewImage {
                switch response.previewPayloadType {
                case .responsePayloadTypeTensor:
                  if let tensor = Tensor<FloatType>(
                    data: response.previewImage, using: [.zip, .fpzip])
                  {
                    previewTensor = Tensor<FloatType>(from: tensor)
                  }
                case .responsePayloadTypePng, .responsePayloadTypeJpeg:
                  previewTensor = tensorFromEncodedImageData(response.previewImage)
                case .responsePayloadTypeUnspecified, .UNRECOGNIZED:
                  if let tensor = Tensor<FloatType>(
                    data: response.previewImage, using: [.zip, .fpzip])
                  {
                    previewTensor = Tensor<FloatType>(from: tensor)
                  } else {
                    previewTensor = tensorFromEncodedImageData(response.previewImage)
                  }
                }
              }
              let isGenerating = feedback(currentSignpost, signpostsSet, previewTensor)
              if !isGenerating {
                logger.info("Stream cancel image generating")
                cancellationQueue.sync {
                  shouldCancel = true
                }
                throw CancellationError()
              }
            }
            if response.hasScaleFactor {
              scaleFactor = Int(response.scaleFactor)
            }
          }
          return ()
        }
      } catch let rpcError as RPCError {
        logger.error("Stream failed with RPC error: \(rpcError)")
        if rpcError.code == .permissionDenied, rpcError.message.contains("throttlePolicy"),
          let requestExceedLimitHandler = requestExceedLimitHandler
        {
          requestExceedLimitHandler()
        }
        resultQueue.sync {
          completionError = .failedWithStatus(rpcError)
        }
      } catch {
        logger.error("Stream failed with error: \(error)")
        resultQueue.sync {
          completionError = .failedWithError(error)
        }
      }
    }

    completionSemaphore.wait()
    if tensors.isEmpty, let completionError = resultQueue.sync(execute: { completionError }) {
      throw completionError
    }
    return (tensors, audios.isEmpty ? nil : audios, scaleFactor)
  }
}
