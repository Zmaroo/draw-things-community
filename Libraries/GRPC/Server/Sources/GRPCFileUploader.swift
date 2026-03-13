import Crypto
import Foundation
import GRPCImageServiceModels
import Logging

public enum GRPCFileUploaderError: Error {
  case notConnected
  case cannotReadFile
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public struct GRPCFileUploader {
  public typealias Call = Task<Void, Never>
  private static let chunkSize = 1 * 1024 * 1024  // 1MiB chunks.
  private let logger = Logger(label: "com.draw-things.grpc-file-uploader")
  public let client: ImageGenerationClientWrapper

  public init(client: ImageGenerationClientWrapper) {
    self.client = client
  }

  public func resume(
    fileUrl: URL,
    progressHandler: @escaping (Int64, Int64) -> Void,
    completionHandler: @escaping (Bool) -> Void
  ) throws -> Call {
    let sharedSecret = client.sharedSecret
    guard let client = client.client else {
      throw GRPCFileUploaderError.notConnected
    }

    guard let fileData = try? Data(contentsOf: fileUrl, options: .mappedIfSafe) else {
      throw GRPCFileUploaderError.cannotReadFile
    }

    let filename = fileUrl.lastPathComponent
    let fileSize = Int64(fileData.count)

    let logger = logger
    let call = Task {
      do {
        // Send message and compute SHA-256 off the main thread.
        let fileHash = Data(SHA256.hash(data: fileData))
        let hexString = fileHash.map { String(format: "%02x", $0) }.joined()
        logger.info("file hash \(hexString)")

        // 1. Send the InitUploadRequest with filename, hash, and total file size.
        let uploadSucceeded = try await client.uploadFile(
          requestProducer: { writer in
            let initRequest = FileUploadRequest.with {
              $0.initRequest = InitUploadRequest.with {
                $0.filename = filename
                $0.sha256 = fileHash
                $0.totalSize = fileSize
              }
              if let sharedSecret = sharedSecret {
                $0.sharedSecret = sharedSecret
              }
            }
            try await writer.write(initRequest)

            var offset: Int64 = 0
            while offset < fileSize {
              let chunkData = fileData.subdata(
                in: Int(offset)..<min(Int(offset + Int64(Self.chunkSize)), fileData.count))
              let chunkRequest = FileUploadRequest.with {
                $0.chunk = FileChunk.with {
                  $0.content = chunkData
                  $0.offset = offset
                }
                if let sharedSecret = sharedSecret {
                  $0.sharedSecret = sharedSecret
                }
              }
              try await writer.write(chunkRequest)
              logger.info("Sent chunk at offset \(offset)")
              offset = Int64(min(Int(offset + Int64(Self.chunkSize)), fileData.count))
            }
          },
          onResponse: { response in
            do {
              var sawFailure = false
              for try await message in response.messages {
                logger.info("server received chunk offset \(message.receivedOffset)")
                progressHandler(message.receivedOffset, fileSize)
                if !message.chunkUploadSuccess {
                  logger.info("failed to upload chunk \(message.message)")
                  sawFailure = true
                }
              }
              return !sawFailure
            } catch {
              logger.error("Failed receiving upload response stream: \(String(describing: error))")
              return false
            }
          })
        completionHandler(uploadSucceeded)
      } catch {
        logger.error("Failed to upload file: \(String(describing: error))")
        completionHandler(false)
      }
    }
    return call
  }

}
