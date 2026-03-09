load("@build_bazel_rules_swift//swift:swift.bzl", "swift_binary", "swift_library")

SWIFT_PROTOBUF_V2_COPTS = [
    "-swift-version",
    "6",
    "-package-name",
    "swift-protobuf",
]

swift_library(
    name = "SwiftProtobuf",
    srcs = glob([
        "Sources/SwiftProtobuf/**/*.swift",
    ]),
    copts = SWIFT_PROTOBUF_V2_COPTS,
    module_name = "SwiftProtobuf",
    visibility = ["//visibility:public"],
    deps = [],
)

swift_library(
    name = "SwiftProtobufPluginLibrary",
    srcs = glob([
        "Sources/SwiftProtobufPluginLibrary/**/*.swift",
    ]),
    copts = SWIFT_PROTOBUF_V2_COPTS,
    module_name = "SwiftProtobufPluginLibrary",
    visibility = ["//visibility:public"],
    deps = [":SwiftProtobuf"],
)

swift_binary(
    name = "protoc-gen-swift",
    srcs = glob([
        "Sources/protoc-gen-swift/**/*.swift",
    ]),
    copts = SWIFT_PROTOBUF_V2_COPTS,
    visibility = ["//visibility:public"],
    deps = [
        ":SwiftProtobuf",
        ":SwiftProtobufPluginLibrary",
    ],
)
