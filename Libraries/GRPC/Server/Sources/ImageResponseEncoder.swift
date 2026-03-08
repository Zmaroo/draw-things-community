import Diffusion
import Foundation
import NNC

#if canImport(CoreGraphics) && canImport(ImageIO) && canImport(UniformTypeIdentifiers)
  import CoreGraphics
  import ImageIO
  import UniformTypeIdentifiers
#endif

enum EncodedImagePayloadType: String {
  case tensor
  case png
  case jpeg
}

enum RequestedImageResponseFormat {
  case tensor
  case png
  case jpeg
}

enum EncodedImageFormat {
  case png
  case jpeg
}

enum ImageResponseEncoder {
  static func encodePreviewImage(
    from previewTensor: Tensor<FloatType>, responseFormat: RequestedImageResponseFormat,
    responseCompression: Bool
  ) -> (payloadType: EncodedImagePayloadType, payload: Data)? {
    switch responseFormat {
    case .tensor:
      let codec: DynamicGraph.Store.Codec = responseCompression ? [.zip, .fpzip] : []
      return (.tensor, previewTensor.data(using: codec))
    case .png:
      guard let data = encodedImageData(from: previewTensor, format: .png) else { return nil }
      return (.png, data)
    case .jpeg:
      guard let data = encodedImageData(from: previewTensor, format: .jpeg) else { return nil }
      return (.jpeg, data)
    }
  }

  static func encodeImages(
    from images: [Tensor<FloatType>]?, responseFormat: RequestedImageResponseFormat,
    responseCompression: Bool
  ) -> (payloadType: EncodedImagePayloadType, payloads: [Data]) {
    switch responseFormat {
    case .tensor:
      let codec: DynamicGraph.Store.Codec = responseCompression ? [.zip, .fpzip] : []
      return (.tensor, images?.compactMap { $0.data(using: codec) } ?? [])
    case .png:
      return (.png, images?.compactMap { encodedImageData(from: $0, format: .png) } ?? [])
    case .jpeg:
      return (.jpeg, images?.compactMap { encodedImageData(from: $0, format: .jpeg) } ?? [])
    }
  }

  static func chunkedPayloads(_ payload: Data, maxChunkSize: Int) -> [Data] {
    guard maxChunkSize > 0 else { return [payload] }
    guard payload.count > maxChunkSize else { return [payload] }
    var chunks = [Data]()
    chunks.reserveCapacity((payload.count + maxChunkSize - 1) / maxChunkSize)
    var offset = 0
    while offset < payload.count {
      let chunkSize = min(maxChunkSize, payload.count - offset)
      chunks.append(payload.subdata(in: offset..<(offset + chunkSize)))
      offset += chunkSize
    }
    return chunks
  }

  #if canImport(CoreGraphics) && canImport(ImageIO) && canImport(UniformTypeIdentifiers)
    private static func encodedImageData(from tensor: Tensor<FloatType>, format: EncodedImageFormat)
      -> Data?
    {
      let shape = tensor.shape
      let height: Int
      let width: Int
      let channels: Int
      switch shape.count {
      case 4:
        guard shape[0] > 0 else { return nil }
        height = shape[1]
        width = shape[2]
        channels = shape[3]
      case 3:
        height = shape[0]
        width = shape[1]
        channels = shape[2]
      default:
        return nil
      }
      guard height > 0, width > 0, channels >= 3 else { return nil }

      let pixelCount = width * height
      var bytes = [UInt8](repeating: 0, count: pixelCount * 4)
      tensor.withUnsafeBytes { rawBuffer in
        guard let fp = rawBuffer.baseAddress?.assumingMemoryBound(to: FloatType.self) else {
          return
        }
        for i in 0..<pixelCount {
          let base = i * channels
          bytes[i * 4] = UInt8(min(max(Int((Float(fp[base]) + 1) * 127.5), 0), 255))
          bytes[i * 4 + 1] = UInt8(min(max(Int((Float(fp[base + 1]) + 1) * 127.5), 0), 255))
          bytes[i * 4 + 2] = UInt8(min(max(Int((Float(fp[base + 2]) + 1) * 127.5), 0), 255))
          bytes[i * 4 + 3] = 255
        }
      }

      let bitmapInfo = CGBitmapInfo(
        rawValue: CGBitmapInfo.byteOrder32Big.rawValue
          | CGImageAlphaInfo.noneSkipLast.rawValue)
      let byteData = Data(bytes)
      guard
        let provider = CGDataProvider(data: byteData as CFData),
        let cgImage = CGImage(
          width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo,
          provider: provider, decode: nil, shouldInterpolate: false,
          intent: .defaultIntent)
      else {
        return nil
      }

      let output = NSMutableData()
      let typeIdentifier: CFString
      switch format {
      case .png:
        typeIdentifier = UTType.png.identifier as CFString
      case .jpeg:
        typeIdentifier = UTType.jpeg.identifier as CFString
      }
      guard
        let destination = CGImageDestinationCreateWithData(
          output as CFMutableData, typeIdentifier, 1, nil)
      else { return nil }
      if format == .jpeg {
        let properties: CFDictionary =
          [
            kCGImageDestinationLossyCompressionQuality: 0.9
          ] as CFDictionary
        CGImageDestinationAddImage(destination, cgImage, properties)
      } else {
        CGImageDestinationAddImage(destination, cgImage, nil)
      }
      guard CGImageDestinationFinalize(destination) else { return nil }
      return output as Data
    }
  #else
    private static func encodedImageData(from tensor: Tensor<FloatType>, format: EncodedImageFormat)
      -> Data?
    {
      nil
    }
  #endif
}
