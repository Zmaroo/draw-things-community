load(
    "@build_bazel_rules_swift//swift:swift.bzl",
    "swift_library",
)

swift_library(
    name = "NIOExtras",
    srcs = glob([
        "Sources/NIOExtras/**/*.swift",
    ]),
    module_name = "NIOExtras",
    visibility = ["//visibility:public"],
    deps = [
        "@SwiftNIO//:NIO",
        "@SwiftNIO//:NIOCore",
        "@SwiftNIO//:NIOHTTP1",
    ],
)

swift_library(
    name = "NIOCertificateReloading",
    srcs = [
        # grpc-swift-nio-transport only needs the CertificateReloader protocol surface.
        # TimedCertificateReloader adds extra package dependencies not currently vendored.
        "Sources/NIOCertificateReloading/CertificateReloader.swift",
    ],
    module_name = "NIOCertificateReloading",
    visibility = ["//visibility:public"],
    deps = [
        "@SwiftNIO//:NIOCore",
        "@SwiftNIO//:NIOTLS",
        "@SwiftNIOSSL//:NIOSSL",
    ],
)
