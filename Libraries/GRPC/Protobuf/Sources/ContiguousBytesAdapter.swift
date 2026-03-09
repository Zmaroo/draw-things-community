import GRPCCore
import SwiftProtobuf

/// Bridges between GRPCCore and SwiftProtobuf contiguous byte protocols.
@usableFromInline
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
struct ContiguousBytesAdapter<Bytes: GRPCContiguousBytes>: GRPCContiguousBytes,
  SwiftProtobufContiguousBytes
{
  @usableFromInline
  var bytes: Bytes

  @inlinable
  init(_ bytes: Bytes) {
    self.bytes = bytes
  }

  @inlinable
  init(repeating: UInt8, count: Int) {
    self.bytes = Bytes(repeating: repeating, count: count)
  }

  @inlinable
  init(_ sequence: some Sequence<UInt8>) {
    self.bytes = Bytes(sequence)
  }

  @inlinable
  var count: Int {
    self.bytes.count
  }

  @inlinable
  func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
    try self.bytes.withUnsafeBytes(body)
  }

  @inlinable
  mutating func withUnsafeMutableBytes<R>(
    _ body: (UnsafeMutableRawBufferPointer) throws -> R
  ) rethrows -> R {
    try self.bytes.withUnsafeMutableBytes(body)
  }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension ContiguousBytesAdapter: Sendable where Bytes: Sendable {}
