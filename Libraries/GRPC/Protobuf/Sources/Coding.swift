import GRPCCore
import SwiftProtobuf

/// Serializes a Protobuf message into contiguous bytes used by gRPC core.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public struct ProtobufSerializer<Message: SwiftProtobuf.Message>: GRPCCore.MessageSerializer {
  public init() {}

  @inlinable
  public func serialize<Bytes: GRPCContiguousBytes>(_ message: Message) throws -> Bytes {
    do {
      let adapter = try message.serializedBytes() as ContiguousBytesAdapter<Bytes>
      return adapter.bytes
    } catch {
      throw RPCError(
        code: .invalidArgument,
        message: "Can't serialize message of type \(type(of: message)).",
        cause: error
      )
    }
  }
}

/// Deserializes contiguous bytes into a Protobuf message.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public struct ProtobufDeserializer<Message: SwiftProtobuf.Message>: GRPCCore.MessageDeserializer {
  public init() {}

  @inlinable
  public func deserialize<Bytes: GRPCContiguousBytes>(_ serializedMessageBytes: Bytes) throws
    -> Message
  {
    do {
      return try Message(serializedBytes: ContiguousBytesAdapter(serializedMessageBytes))
    } catch {
      throw RPCError(
        code: .invalidArgument,
        message: "Can't deserialize to message of type \(Message.self).",
        cause: error
      )
    }
  }
}
