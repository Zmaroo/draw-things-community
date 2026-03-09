load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "InternalCollectionsUtilities",
    srcs = glob([
        "Sources/InternalCollectionsUtilities/**/*.swift",
    ]),
    module_name = "InternalCollectionsUtilities",
)

swift_library(
    name = "DequeModule",
    srcs = glob([
        "Sources/DequeModule/**/*.swift",
    ]),
    module_name = "DequeModule",
    visibility = ["//visibility:public"],
    deps = [
        ":InternalCollectionsUtilities",
    ],
)
