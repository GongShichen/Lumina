// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "LocalAgentRuntime",
    platforms: [
        .iOS(.v26),
        .macOS(.v15)
    ],
    products: [
        .library(name: "AgentRuntime", targets: ["AgentRuntime"]),
        .library(name: "PersonalMemory", targets: ["PersonalMemory"]),
        .library(name: "LuminaModelRuntime", targets: ["LuminaModelRuntime"]),
        .library(name: "LuminaMarkdownUI", targets: ["LuminaMarkdownUI"]),
        .library(name: "LuminaAppCore", targets: ["LuminaAppCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.8.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.0.0")
    ],
    targets: [
        .target(
            name: "AgentRuntime",
            exclude: ["Info.plist"]
        ),
        .target(
            name: "PersonalMemory",
            exclude: ["Info.plist"]
        ),
        .target(
            name: "LuminaModelRuntime",
            dependencies: [
                "AgentRuntime",
                "PersonalMemory",
                .product(name: "Tokenizers", package: "swift-transformers")
            ],
            exclude: ["Info.plist"]
        ),
        .target(
            name: "LuminaMarkdownUI",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown")
            ],
            exclude: ["Info.plist"]
        ),
        .target(
            name: "LuminaAppCore",
            dependencies: ["AgentRuntime", "PersonalMemory"],
            exclude: ["Info.plist"]
        ),
        .testTarget(
            name: "AgentRuntimeTests",
            dependencies: ["AgentRuntime", "LuminaModelRuntime"]
        ),
        .testTarget(
            name: "LuminaMarkdownUITests",
            dependencies: ["LuminaMarkdownUI"]
        ),
        .testTarget(
            name: "PersonalMemoryTests",
            dependencies: ["PersonalMemory", "LuminaModelRuntime"]
        ),
        .testTarget(
            name: "LuminaAppCoreTests",
            dependencies: ["LuminaAppCore", "AgentRuntime", "PersonalMemory", "LuminaModelRuntime"]
        )
    ]
)
