import LuminaAgentClient
import Foundation

public struct LuminaLocationCurrentTool: LuminaAgentTool {
    public typealias CurrentLocation = @Sendable () async throws -> LuminaLocationSnapshot

    private let currentLocation: CurrentLocation

    public init(currentLocation: @escaping CurrentLocation = {
        throw CancellationError()
    }) {
        self.currentLocation = currentLocation
    }

    public var schema: LuminaToolSchema {
        LuminaToolSchema(
            name: "location.current",
            description: "获取本机当前位置摘要。",
            parameters: [
                LuminaToolParameterSchema(name: "reverseGeocode", type: .bool, description: "是否需要城市/区域摘要。", required: false)
            ],
            sideEffect: .readOnly,
            sensitivity: .privateData,
            acceptedInputModalities: [.text, .structuredData],
            outputModalities: [.text, .structuredData]
        )
    }

    public func call(arguments: [String: LuminaJSONValue], cancellation: LuminaCancellationToken) async throws -> LuminaToolResult {
        try cancellation.checkCancellation()
        let snapshot = try await currentLocation()
        try cancellation.checkCancellation()
        let summary = snapshot.locality.map {
            "当前位置在 \($0)，精度约 \(Int(snapshot.horizontalAccuracy)) 米。"
        } ?? "当前位置纬度 \(snapshot.latitude)，经度 \(snapshot.longitude)，精度约 \(Int(snapshot.horizontalAccuracy)) 米。"
        return LuminaToolResult(
            callID: UUID(),
            toolName: schema.name,
            status: .succeeded,
            output: [
                "latitude": .number(snapshot.latitude),
                "longitude": .number(snapshot.longitude),
                "horizontalAccuracy": .number(snapshot.horizontalAccuracy),
                "timestamp": .string(ISO8601DateFormatter().string(from: snapshot.timestamp)),
                "locality": snapshot.locality.map(LuminaJSONValue.string) ?? .null,
                "summary": .string(summary)
            ],
            content: [.markdown("## 当前位置\n\n\(summary)")]
        )
    }
}
