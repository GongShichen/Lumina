// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "LocalAgentRuntime",
    platforms: [
        .iOS(.v26),
        .macOS(.v15)
    ],
    products: [
        .library(name: "LuminaAgentRuntime", targets: ["LuminaAgentRuntime"]),
        .library(name: "LuminaAgentClient", targets: ["LuminaAgentClient"]),
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
            name: "LuminaAgentRuntime",
            path: "Sources/LuminaAgentRuntime",
            exclude: [],
            sources: [
                "Callbacks/src",
                "Context/src",
                "Contract/src",
                "Envelope/src",
                "Hooks/src",
                "Json/src",
                "Observation/src",
                "Pipeline/src",
                "Planner/src",
                "ReAct/src",
                "Session/src",
                "Status/src",
                "Streaming/src",
                "Tool/src",
                "Trace/src",
                "Runtime/src"
            ],
            publicHeadersPath: "Runtime/include",
            cxxSettings: [
                .headerSearchPath("Budget/include"),
                .headerSearchPath("Callbacks/include"),
                .headerSearchPath("Context/include"),
                .headerSearchPath("Contract/include"),
                .headerSearchPath("Envelope/include"),
                .headerSearchPath("Hooks/include"),
                .headerSearchPath("Json/include"),
                .headerSearchPath("Observation/include"),
                .headerSearchPath("Pipeline/include"),
                .headerSearchPath("Planner/include"),
                .headerSearchPath("ReAct/include"),
                .headerSearchPath("Session/include"),
                .headerSearchPath("Status/include"),
                .headerSearchPath("Streaming/include"),
                .headerSearchPath("Tool/include"),
                .headerSearchPath("Trace/include"),
                .headerSearchPath("Runtime/include")
            ]
        ),
        .target(
            name: "LuminaAgentClient",
            dependencies: ["LuminaAgentRuntime"],
            path: "Sources/LuminaAgentClient"
        ),
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
                "LuminaAgentClient",
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
            dependencies: ["LuminaAgentClient", "PersonalMemory"],
            exclude: ["Info.plist"]
        ),
        .testTarget(
            name: "LuminaAgentRuntimeTests",
            dependencies: ["LuminaAgentClient", "LuminaAgentRuntime", "LuminaModelRuntime"]
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
            dependencies: ["LuminaAppCore", "LuminaAgentClient", "LuminaAgentRuntime", "PersonalMemory", "LuminaModelRuntime"]
        )
    ]
)
