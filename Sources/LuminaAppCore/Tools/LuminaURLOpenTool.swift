import LuminaAgentClient
import Foundation

public struct LuminaURLOpenTool: LuminaAgentTool {
    public typealias OpenURL = @Sendable (URL) async -> Bool

    private let openURL: OpenURL

    public init(openURL: @escaping OpenURL = { _ in true }) {
        self.openURL = openURL
    }

    public var schema: LuminaToolSchema {
        LuminaToolSchema(
            name: "url.open",
            description: "打开 URL、地图搜索或系统设置。",
            parameters: [
                LuminaToolParameterSchema(name: "url", type: .string, description: "要打开的 URL。", required: false),
                LuminaToolParameterSchema(name: "query", type: .string, description: "地图或网页搜索词。", required: false),
                LuminaToolParameterSchema(name: "kind", type: .string, description: "url、map 或 settings。", required: false)
            ],
            sideEffect: .externalCommunication,
            sensitivity: .sensitive,
            acceptedInputModalities: [.text, .structuredData],
            outputModalities: [.text, .structuredData]
        )
    }

    public func call(arguments: [String: LuminaJSONValue], cancellation: LuminaCancellationToken) async throws -> LuminaToolResult {
        try cancellation.checkCancellation()
        let url = Self.url(arguments: arguments)
        let didOpen = await openURL(url)
        return LuminaToolResult(
            callID: UUID(),
            toolName: schema.name,
            status: didOpen ? .succeeded : .failed,
            output: ["url": .string(url.absoluteString), "opened": .bool(didOpen)],
            content: [.markdown(didOpen ? "## 已打开\n\n\(url.absoluteString)" : "## 打开失败\n\n\(url.absoluteString)")],
            errorMessage: didOpen ? nil : "系统没有接受打开请求。"
        )
    }

    private static func url(arguments: [String: LuminaJSONValue]) -> URL {
        let kind = arguments.string("kind")?.lowercased()
        if kind == "settings" {
            return URL(string: "app-settings:")!
        }
        if kind == "map" {
            let query = arguments.string("query") ?? arguments.string("url") ?? ""
            let escaped = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            return URL(string: "http://maps.apple.com/?q=\(escaped)")!
        }
        if let raw = arguments.string("url"),
           let url = URL(string: raw) {
            return url
        }
        let query = arguments.string("query") ?? ""
        let escaped = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "https://www.google.com/search?q=\(escaped)")!
    }
}
