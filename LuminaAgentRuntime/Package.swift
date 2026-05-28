// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "LuminaAgentRuntime",
    platforms: [
        .iOS(.v26),
        .macOS(.v15)
    ],
    products: [
        .library(name: "LuminaAgentRuntime", targets: ["LuminaAgentRuntime"]),
        .library(name: "LuminaAgentRuntimeCore", targets: ["LuminaAgentRuntimeCore"]),
        .library(name: "LuminaAgentRuntimeApple", targets: ["LuminaAgentRuntimeApple"])
    ],
    targets: [
        .target(
            name: "LuminaAgentRuntimeCore",
            path: "Sources/LuminaAgentRuntimeCore",
            sources: [
                "Budget/src",
                "Callbacks/src",
                "Context/src",
                "Contract/src",
                "Envelope/src",
                "Events/src",
                "Execution/src",
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
                .headerSearchPath("Events/include"),
                .headerSearchPath("Execution/include"),
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
            name: "LuminaAgentRuntimeApple",
            dependencies: ["LuminaAgentRuntimeCore"],
            path: "Bindings/Apple/Sources/LuminaAgentRuntimeApple"
        ),
        .target(
            name: "LuminaAgentRuntime",
            dependencies: ["LuminaAgentRuntimeApple"],
            path: "Sources/LuminaAgentRuntime"
        ),
        .testTarget(
            name: "LuminaAgentRuntimeTests",
            dependencies: ["LuminaAgentRuntime", "LuminaAgentRuntimeApple", "LuminaAgentRuntimeCore"]
        )
    ]
)
