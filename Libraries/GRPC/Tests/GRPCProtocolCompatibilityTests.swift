import Foundation
import XCTest

@testable import GRPCImageServiceModels
@testable import GRPCServer

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
    request.responseFormat = .png  // legacy compatibility field
    request.previewResponseFormat = .jpeg
    request.finalResponseFormat = .png
    request.previewEveryNsteps = 2

    let bytes = try request.serializedData()
    let decoded = try ImageGenerationRequest(serializedBytes: bytes)

    XCTAssertEqual(decoded.responseFormat, .png)
    XCTAssertEqual(decoded.previewResponseFormat, .jpeg)
    XCTAssertEqual(decoded.finalResponseFormat, .png)
    XCTAssertEqual(decoded.previewEveryNsteps, 2)
  }

  func testResponsePayloadTypesRoundTrip() throws {
    var response = ImageGenerationResponse()
    response.previewPayloadType = .png
    response.finalPayloadType = .jpeg

    let bytes = try response.serializedData()
    let decoded = try ImageGenerationResponse(serializedBytes: bytes)

    XCTAssertEqual(decoded.previewPayloadType, .png)
    XCTAssertEqual(decoded.finalPayloadType, .jpeg)
  }

  func testResponseFormatZeroDecodesAsUnspecifiedAlias() throws {
    var request = ImageGenerationRequest()
    request.responseFormat = .unspecified

    let bytes = try request.serializedData()
    let decoded = try ImageGenerationRequest(serializedBytes: bytes)

    XCTAssertEqual(decoded.responseFormat, .unspecified)
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

  func testEchoCapabilitiesDescriptorIncludesExpectedKeys() {
    let descriptor = ImageGenerationServiceImpl.grpcCapabilities(enableModelBrowsing: true)
    XCTAssertTrue(descriptor.contains("protocol_version=2"))
    XCTAssertTrue(descriptor.contains("split_response_formats=true"))
    XCTAssertTrue(descriptor.contains("payload_type_fields=true"))
    XCTAssertTrue(descriptor.contains("preview_single_payload=true"))
    XCTAssertTrue(descriptor.contains("default_response=tensor"))
    XCTAssertTrue(descriptor.contains("model_browsing=true"))
  }

  func testTraceTagsIncludeRequiredFields() {
    let tags = ImageGenerationServiceImpl.grpcTraceTags(
      requestID: "req-123",
      eventType: "final_image",
      payloadType: .png,
      chunkIndex: 1,
      chunkTotal: 4,
      isTerminal: false
    )
    XCTAssertTrue(tags.contains("request_id=req-123"))
    XCTAssertTrue(tags.contains("event_type=final_image"))
    XCTAssertTrue(tags.contains("payload_type=png"))
    XCTAssertTrue(tags.contains("chunk_index=1"))
    XCTAssertTrue(tags.contains("chunk_total=4"))
    XCTAssertTrue(tags.contains("is_terminal=false"))
  }
}
