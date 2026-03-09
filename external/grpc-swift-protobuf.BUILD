load(
    "@build_bazel_rules_swift//swift:swift.bzl",
    "swift_binary",
    "swift_library",
)

V2_PROTOBUF_SWIFTCOPTS = [
    "-swift-version",
    "6",
    "-package-name",
    "grpc-swift-protobuf",
    "-enable-experimental-feature",
    "AvailabilityMacro=gRPCSwiftProtobuf 2.0:macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0",
    "-enable-experimental-feature",
    "AvailabilityMacro=gRPCSwiftProtobuf 2.1:macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0",
    "-enable-upcoming-feature",
    "ExistentialAny",
    "-enable-upcoming-feature",
    "InternalImportsByDefault",
    "-enable-upcoming-feature",
    "MemberImportVisibility",
]

swift_library(
    name = "GRPCProtobuf",
    srcs = glob(
        ["Sources/GRPCProtobuf/**/*.swift"],
        exclude = ["Sources/GRPCProtobuf/Documentation.docc/**"],
    ),
    copts = V2_PROTOBUF_SWIFTCOPTS,
    module_name = "GRPCProtobuf",
    visibility = ["//visibility:public"],
    deps = [
        "@SwiftProtobuf",
        "@grpc-swift-2//:GRPCCore",
    ],
)

swift_library(
    name = "GRPCProtobufCodeGen",
    srcs = glob(["Sources/GRPCProtobufCodeGen/**/*.swift"]),
    copts = V2_PROTOBUF_SWIFTCOPTS,
    module_name = "GRPCProtobufCodeGen",
    visibility = ["//visibility:public"],
    deps = [
        "@SwiftProtobuf//:SwiftProtobufPluginLibrary",
        "@grpc-swift-2//:GRPCCodeGen",
    ],
)

swift_binary(
    name = "protoc-gen-grpc-swift-2",
    srcs = glob(["Sources/protoc-gen-grpc-swift-2/**/*.swift"]),
    copts = V2_PROTOBUF_SWIFTCOPTS,
    visibility = ["//visibility:public"],
    deps = [
        ":GRPCProtobufCodeGen",
        "@SwiftProtobuf",
        "@SwiftProtobuf//:SwiftProtobufPluginLibrary",
        "@grpc-swift-2//:GRPCCodeGen",
    ],
)
