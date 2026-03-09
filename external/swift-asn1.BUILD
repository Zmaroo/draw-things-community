load(
    "@build_bazel_rules_swift//swift:swift.bzl",
    "swift_library",
)

swift_library(
    name = "SwiftASN1",
    srcs = glob(
        ["Sources/SwiftASN1/**/*.swift"],
        exclude = ["Sources/SwiftASN1/**/*.docc/**"],
    ),
    module_name = "SwiftASN1",
    visibility = ["//visibility:public"],
    deps = [],
)
