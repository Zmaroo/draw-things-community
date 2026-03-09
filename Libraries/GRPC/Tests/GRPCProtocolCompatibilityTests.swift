import Foundation
import XCTest

@testable import GRPCImageServiceModels

final class GRPCProtocolCompatibilityTests: XCTestCase {
  private func reassembleGeneratedImages(from responses: [ImageGenerationResponse]) -> [Data] {
    var payloads: [Data] = []
    var pendingChunk = Data()

    for response in responses {
      guard !response.generatedImages.isEmpty else { continue }

      switch response.chunkState {
      case .moreChunks:
        for chunk in response.generatedImages {
          pendingChunk.append(chunk)
        }
      case .lastChunk:
        if !pendingChunk.isEmpty {
          for chunk in response.generatedImages {
            pendingChunk.append(chunk)
          }
          payloads.append(pendingChunk)
          pendingChunk.removeAll(keepingCapacity: false)
        } else {
          payloads.append(contentsOf: response.generatedImages)
        }
      case .UNRECOGNIZED:
        payloads.append(contentsOf: response.generatedImages)
      }
    }

    if !pendingChunk.isEmpty {
      payloads.append(pendingChunk)
    }

    return payloads
  }

  func testRequestSplitFormatsRoundTrip() throws {
    var request = ImageGenerationRequest()
    request.responseFormat = .responseFormatPng  // legacy compatibility field
    request.previewResponseFormat = .responseFormatJpeg
    request.finalResponseFormat = .responseFormatPng
    request.previewEveryNSteps = 2

    let bytes = try request.serializedData()
    let decoded = try ImageGenerationRequest(serializedBytes: bytes)

    XCTAssertEqual(decoded.responseFormat, .responseFormatPng)
    XCTAssertEqual(decoded.previewResponseFormat, .responseFormatJpeg)
    XCTAssertEqual(decoded.finalResponseFormat, .responseFormatPng)
    XCTAssertEqual(decoded.previewEveryNSteps, 2)
  }

  func testResponsePayloadTypesRoundTrip() throws {
    var response = ImageGenerationResponse()
    response.previewPayloadType = .responsePayloadTypePng
    response.finalPayloadType = .responsePayloadTypeJpeg

    let bytes = try response.serializedData()
    let decoded = try ImageGenerationResponse(serializedBytes: bytes)

    XCTAssertEqual(decoded.previewPayloadType, .responsePayloadTypePng)
    XCTAssertEqual(decoded.finalPayloadType, .responsePayloadTypeJpeg)
  }

  func testResponseFormatZeroDecodesAsUnspecifiedAlias() throws {
    var request = ImageGenerationRequest()
    request.responseFormat = .responseFormatUnspecified

    let bytes = try request.serializedData()
    let decoded = try ImageGenerationRequest(serializedBytes: bytes)

    XCTAssertEqual(decoded.responseFormat, .responseFormatUnspecified)
  }

  func testChunkReassemblyIsStableWhenLastChunkHasNoPayload() {
    var more = ImageGenerationResponse()
    more.chunkState = .moreChunks
    more.generatedImages = [
      Data([0x01, 0x02]),
      Data([0x03, 0x04]),
    ]

    var last = ImageGenerationResponse()
    last.chunkState = .lastChunk
    last.generatedImages = []

    let payloads = reassembleGeneratedImages(from: [more, last])
    XCTAssertEqual(payloads.count, 1)
    XCTAssertEqual(payloads[0], Data([0x01, 0x02, 0x03, 0x04]))
  }
}
