import LuminaAgentClient
import CoreLocation
import Foundation

struct LuminaLocationCurrentTool: LuminaAgentTool {
    var schema: LuminaToolSchema {
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

    func call(arguments: [String: LuminaJSONValue], cancellation: LuminaCancellationToken) async throws -> LuminaToolResult {
        try cancellation.checkCancellation()
        let location = try await LuminaLocationRequestCoordinator().currentLocation()
        let locality = try? await reverseGeocode(location)
        let summary = locality.map {
            "当前位置在 \($0)，精度约 \(Int(location.horizontalAccuracy)) 米。"
        } ?? "当前位置纬度 \(location.coordinate.latitude)，经度 \(location.coordinate.longitude)，精度约 \(Int(location.horizontalAccuracy)) 米。"
        return LuminaToolResult(
            callID: UUID(),
            toolName: schema.name,
            status: .succeeded,
            output: [
                "latitude": .number(location.coordinate.latitude),
                "longitude": .number(location.coordinate.longitude),
                "horizontalAccuracy": .number(location.horizontalAccuracy),
                "timestamp": .string(ISO8601DateFormatter().string(from: location.timestamp)),
                "locality": locality.map(LuminaJSONValue.string) ?? .null,
                "summary": .string(summary)
            ],
            content: [.markdown("## 当前位置\n\n\(summary)")]
        )
    }

    private func reverseGeocode(_ location: CLLocation) async throws -> String? {
        #if targetEnvironment(macCatalyst)
        return nil
        #else
        let placemarks = try await CLGeocoder().reverseGeocodeLocation(location)
        guard let placemark = placemarks.first else { return nil }
        return [placemark.locality, placemark.administrativeArea, placemark.country]
            .compactMap { $0 }
            .joined(separator: " ")
        #endif
    }
}
