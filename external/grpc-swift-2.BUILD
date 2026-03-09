load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

V2_SWIFTCOPTS = [
    "-swift-version",
    "6",
    "-package-name",
    "grpc-swift-2",
    "-enable-experimental-feature",
    "AvailabilityMacro=gRPCSwift 2.0:macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0",
    "-enable-experimental-feature",
    "AvailabilityMacro=gRPCSwift 2.1:macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0",
    "-enable-experimental-feature",
    "AvailabilityMacro=gRPCSwift 2.2:macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0",
    "-enable-upcoming-feature",
    "ExistentialAny",
    "-enable-upcoming-feature",
    "InternalImportsByDefault",
    "-enable-upcoming-feature",
    "MemberImportVisibility",
]

swift_library(
    name = "GRPCCore",
    srcs = glob(
        ["Sources/GRPCCore/**/*.swift"],
        exclude = ["Sources/GRPCCore/Documentation.docc/**"],
    ),
    copts = V2_SWIFTCOPTS,
    module_name = "GRPCCore",
    visibility = ["//visibility:public"],
    deps = [
        "@SwiftCollections//:Collections",
    ],
)

swift_library(
    name = "GRPCCodeGen",
    srcs = glob(["Sources/GRPCCodeGen/**/*.swift"]),
    copts = V2_SWIFTCOPTS,
    module_name = "GRPCCodeGen",
    visibility = ["//visibility:public"],
    deps = [],
)

swift_library(
    name = "GRPCInProcessTransport",
    srcs = glob(
        ["Sources/GRPCInProcessTransport/**/*.swift"],
        exclude = ["Sources/GRPCInProcessTransport/Documentation.docc/**"],
    ),
    copts = V2_SWIFTCOPTS,
    module_name = "GRPCInProcessTransport",
    visibility = ["//visibility:public"],
    deps = [
        ":GRPCCore",
    ],
)
