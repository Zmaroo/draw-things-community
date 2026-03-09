load(
    "@build_bazel_rules_swift//swift:swift.bzl",
    "swift_interop_hint",
    "swift_library",
)

V2_NIO_TRANSPORT_SWIFTCOPTS = [
    "-swift-version",
    "6",
    "-package-name",
    "grpc-swift-nio-transport",
    "-enable-experimental-feature",
    "AvailabilityMacro=gRPCSwiftNIOTransport 2.0:macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0",
    "-enable-experimental-feature",
    "AvailabilityMacro=gRPCSwiftNIOTransport 2.1:macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0",
    "-enable-experimental-feature",
    "AvailabilityMacro=gRPCSwiftNIOTransport 2.2:macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0",
    "-enable-experimental-feature",
    "AvailabilityMacro=gRPCSwiftNIOTransport 2.3:macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0",
    "-enable-experimental-feature",
    "AvailabilityMacro=gRPCSwiftNIOTransport 2.4:macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0",
    "-enable-upcoming-feature",
    "ExistentialAny",
    "-enable-upcoming-feature",
    "InternalImportsByDefault",
    "-enable-upcoming-feature",
    "MemberImportVisibility",
]

cc_library(
    name = "CGRPCNIOTransportZlib",
    srcs = glob([
        "Sources/CGRPCNIOTransportZlib/**/*.c",
    ]),
    hdrs = glob([
        "Sources/CGRPCNIOTransportZlib/include/**/*.h",
    ]),
    aspect_hints = [":CGRPCNIOTransportZlib_swift_interop"],
    includes = ["Sources/CGRPCNIOTransportZlib/include"],
    linkopts = ["-lz"],
    tags = ["swift_module=CGRPCNIOTransportZlib"],
    visibility = ["//visibility:public"],
)

swift_interop_hint(
    name = "CGRPCNIOTransportZlib_swift_interop",
    module_name = "CGRPCNIOTransportZlib",
)

swift_library(
    name = "GRPCNIOTransportCore",
    srcs = glob(
        ["Sources/GRPCNIOTransportCore/**/*.swift"],
        exclude = ["Sources/GRPCNIOTransportCore/Documentation.docc/**"],
    ),
    copts = V2_NIO_TRANSPORT_SWIFTCOPTS,
    module_name = "GRPCNIOTransportCore",
    visibility = ["//visibility:public"],
    deps = [
        ":CGRPCNIOTransportZlib",
        "@SwiftNIO//:NIOCore",
        "@SwiftNIOExtras//:NIOExtras",
        "@SwiftNIOHTTP2//:NIOHTTP2",
        "@grpc-swift-2//:GRPCCore",
    ],
)

swift_library(
    name = "GRPCNIOTransportHTTP2Posix",
    srcs = glob(
        ["Sources/GRPCNIOTransportHTTP2Posix/**/*.swift"],
        exclude = ["Sources/GRPCNIOTransportHTTP2Posix/Documentation.docc/**"],
    ),
    copts = V2_NIO_TRANSPORT_SWIFTCOPTS,
    module_name = "GRPCNIOTransportHTTP2Posix",
    visibility = ["//visibility:public"],
    deps = [
        ":GRPCNIOTransportCore",
        "@SwiftASN1",
        "@SwiftCertificates//:X509",
        "@SwiftNIO//:NIOPosix",
        "@SwiftNIOExtras//:NIOCertificateReloading",
        "@SwiftNIOSSL//:NIOSSL",
        "@grpc-swift-2//:GRPCCore",
    ],
)

swift_library(
    name = "GRPCNIOTransportHTTP2TransportServices",
    srcs = glob(
        ["Sources/GRPCNIOTransportHTTP2TransportServices/**/*.swift"],
        exclude = ["Sources/GRPCNIOTransportHTTP2TransportServices/Documentation.docc/**"],
    ),
    copts = V2_NIO_TRANSPORT_SWIFTCOPTS,
    module_name = "GRPCNIOTransportHTTP2TransportServices",
    visibility = ["//visibility:public"],
    deps = [
        ":GRPCNIOTransportCore",
        "@SwiftNIOTransportService//:NIOTransportServices",
        "@grpc-swift-2//:GRPCCore",
    ],
)

swift_library(
    name = "GRPCNIOTransportHTTP2",
    srcs = glob(
        ["Sources/GRPCNIOTransportHTTP2/**/*.swift"],
        exclude = ["Sources/GRPCNIOTransportHTTP2/Documentation.docc/**"],
    ),
    copts = V2_NIO_TRANSPORT_SWIFTCOPTS,
    module_name = "GRPCNIOTransportHTTP2",
    visibility = ["//visibility:public"],
    deps = [
        ":GRPCNIOTransportHTTP2Posix",
        ":GRPCNIOTransportHTTP2TransportServices",
    ],
)
