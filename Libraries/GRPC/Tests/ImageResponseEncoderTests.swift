import Diffusion
import Foundation
import NNC
import XCTest

@testable import GRPCServer

#if canImport(CoreGraphics) && canImport(ImageIO)
  import CoreGraphics
  import ImageIO
#endif

final class ImageResponseEncoderTests: XCTestCase {
  private func sampleTensor(width: Int = 8, height: Int = 8) -> Tensor<FloatType> {
    var tensor = Tensor<FloatType>(.CPU, .NHWC(1, height, width, 3))
    tensor.withUnsafeMutableBytes { rawBuffer in
      guard let fp = rawBuffer.baseAddress?.assumingMemoryBound(to: FloatType.self) else { return }
      for y in 0..<height {
        for x in 0..<width {
          let index = (y * width + x) * 3
          let xf = Float(x) / Float(max(width - 1, 1))
          let yf = Float(y) / Float(max(height - 1, 1))
          fp[index] = FloatType(xf * 2 - 1)
          fp[index + 1] = FloatType(yf * 2 - 1)
          fp[index + 2] = FloatType(0)
        }
      }
    }
    return tensor
  }

  #if canImport(CoreGraphics) && canImport(ImageIO)
    private func decodesAsImage(_ data: Data) -> Bool {
      guard
        let source = CGImageSourceCreateWithData(data as CFData, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
      else {
        return false
      }
      return image.width > 0 && image.height > 0
    }
  #endif

  func testPngResponsePayloadDecodesAsImage() throws {
    #if canImport(CoreGraphics) && canImport(ImageIO)
      let tensor = sampleTensor()
      let encoded = ImageResponseEncoder.encodeImages(
        from: [tensor], responseFormat: .png, responseCompression: false)
      XCTAssertEqual(encoded.payloadType, EncodedImagePayloadType.png)
      XCTAssertEqual(encoded.payloads.count, 1)
      let payload = try XCTUnwrap(encoded.payloads.first)
      XCTAssertTrue(decodesAsImage(payload))
    #else
      throw XCTSkip("ImageIO unavailable on this platform")
    #endif
  }

  func testChunkedPngPayloadCanBeReassembled() throws {
    #if canImport(CoreGraphics) && canImport(ImageIO)
      let tensor = sampleTensor(width: 64, height: 64)
      let encoded = ImageResponseEncoder.encodeImages(
        from: [tensor], responseFormat: .png, responseCompression: false)
      let payload = try XCTUnwrap(encoded.payloads.first)
      let chunks = ImageResponseEncoder.chunkedPayloads(payload, maxChunkSize: 64)
      XCTAssertGreaterThan(chunks.count, 1)
      let reassembled = chunks.reduce(into: Data()) { partial, chunk in
        partial.append(chunk)
      }
      XCTAssertEqual(payload, reassembled)
      XCTAssertTrue(decodesAsImage(reassembled))
    #else
      throw XCTSkip("ImageIO unavailable on this platform")
    #endif
  }

  func testPngPreviewPayloadDecodesAsImage() throws {
    #if canImport(CoreGraphics) && canImport(ImageIO)
      let tensor = sampleTensor()
      let encodedPreview = try XCTUnwrap(
        ImageResponseEncoder.encodePreviewImage(
          from: tensor, responseFormat: .png, responseCompression: false))
      XCTAssertEqual(encodedPreview.payloadType, EncodedImagePayloadType.png)
      XCTAssertTrue(decodesAsImage(encodedPreview.payload))
    #else
      throw XCTSkip("ImageIO unavailable on this platform")
    #endif
  }
}
