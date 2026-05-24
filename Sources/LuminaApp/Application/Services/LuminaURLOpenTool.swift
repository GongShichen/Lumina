import AgentRuntime
import Foundation

#if canImport(UIKit)
import UIKit
#endif

#if os(macOS) && !targetEnvironment(macCatalyst) && canImport(AppKit)
import AppKit
#endif

struct LuminaURLOpenTool: LuminaAgentTool {
    var schema: LuminaToolSchema {
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

    func call(arguments: [String: LuminaJSONValue], cancellation: LuminaCancellationToken) async throws -> LuminaToolResult {
        try cancellation.checkCancellation()
        let url = Self.url(arguments: arguments)
        let didOpen = await open(url)
        return LuminaToolResult(
            callID: UUID(),
            toolName: schema.name,
            status: didOpen ? .succeeded : .failed,
            output: ["url": .string(url.absoluteString), "opened": .bool(didOpen)],
            content: [.markdown(didOpen ? "## 已打开\n\n\(url.absoluteString)" : "## 打开失败\n\n\(url.absoluteString)")],
            errorMessage: didOpen ? nil : "系统没有接受打开请求。"
        )
    }

    private func open(_ url: URL) async -> Bool {
        #if canImport(UIKit)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                UIApplication.shared.open(url) { success in
                    continuation.resume(returning: success)
                }
            }
        }
        #elseif os(macOS) && !targetEnvironment(macCatalyst) && canImport(AppKit)
        await MainActor.run {
            NSWorkspace.shared.open(url)
        }
        #else
        false
        #endif
    }

    private static func url(arguments: [String: LuminaJSONValue]) -> URL {
        let kind = arguments.string("kind")?.lowercased()
        if kind == "settings" {
            #if canImport(UIKit)
            return URL(string: UIApplication.openSettingsURLString)!
            #else
            return URL(string: "x-apple.systempreferences:")!
            #endif
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
