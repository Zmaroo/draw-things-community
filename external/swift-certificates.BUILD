load(
    "@build_bazel_rules_swift//swift:swift.bzl",
    "swift_library",
)

swift_library(
    name = "_CertificateInternals",
    srcs = glob(["Sources/_CertificateInternals/**/*.swift"]),
    module_name = "_CertificateInternals",
    visibility = ["//visibility:public"],
    deps = [],
)

swift_library(
    name = "X509",
    srcs = glob(
        ["Sources/X509/**/*.swift"],
        exclude = ["Sources/X509/**/*.docc/**"],
    ),
    module_name = "X509",
    visibility = ["//visibility:public"],
    deps = [
        ":_CertificateInternals",
        "@SwiftASN1",
        "@SwiftCrypto//:Crypto",
        "@SwiftCrypto//:_CryptoExtras",
    ],
)
