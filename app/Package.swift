// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "LuminaApp",
    platforms: [
        .iOS(.v26),
        .macOS(.v15)
    ],
    products: [
        .library(name: "PersonalMemory", targets: ["PersonalMemory"]),
        .library(name: "LuminaModelRuntime", targets: ["LuminaModelRuntime"]),
        .library(name: "LuminaMarkdownUI", targets: ["LuminaMarkdownUI"]),
        .library(name: "LuminaAppCore", targets: ["LuminaAppCore"])
    ],
    dependencies: [
        .package(path: "../LuminaAgentRuntime"),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.8.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.0.0")
    ],
    targets: [
        .target(
            name: "PersonalMemory",
            exclude: ["Info.plist"]
        ),
        .target(
            name: "LuminaModelRuntimeCore",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("Metal")
            ]
        ),
        .target(
            name: "LuminaModelRuntime",
            dependencies: [
                .product(name: "LuminaAgentRuntime", package: "LuminaAgentRuntime"),
                "LuminaModelRuntimeCore",
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
            dependencies: [
                .product(name: "LuminaAgentRuntime", package: "LuminaAgentRuntime"),
                "PersonalMemory"
            ],
            exclude: ["Info.plist"]
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
            dependencies: [
                "LuminaAppCore",
                .product(name: "LuminaAgentRuntime", package: "LuminaAgentRuntime"),
                .product(name: "LuminaAgentRuntimeCore", package: "LuminaAgentRuntime"),
                "PersonalMemory",
                "LuminaModelRuntime"
            ]
        )
    ]
)
