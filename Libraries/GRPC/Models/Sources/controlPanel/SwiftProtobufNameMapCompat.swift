import SwiftProtobuf

extension SwiftProtobuf._NameMap {
  /// Compatibility shim for generated code expecting older SwiftProtobuf bytecode initializer.
  init(bytecode: StaticString) {
    self.init()
  }

  /// Some generated files pass a String literal instead of StaticString.
  init(bytecode: String) {
    self.init()
  }
}
