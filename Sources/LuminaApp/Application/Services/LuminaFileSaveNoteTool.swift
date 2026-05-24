import AgentRuntime
import Foundation

struct LuminaFileSaveNoteTool: LuminaAgentTool {
    let documentsDirectory: URL

    var schema: LuminaToolSchema {
        LuminaToolSchema(
            name: "file.save_note",
            description: "把文本保存为 App Documents 目录下的 Markdown 文件。",
            parameters: [
                LuminaToolParameterSchema(name: "title", type: .string, description: "文件标题。", required: false),
                LuminaToolParameterSchema(name: "body", type: .string, description: "要保存的正文。", sensitive: true),
                LuminaToolParameterSchema(name: "filename", type: .string, description: "文件名。", required: false)
            ],
            sideEffect: .appLocalWrite,
            sensitivity: .sensitive,
            acceptedInputModalities: [.text, .structuredData],
            outputModalities: [.text, .structuredData]
        )
    }

    func call(arguments: [String: LuminaJSONValue], cancellation: LuminaCancellationToken) async throws -> LuminaToolResult {
        try cancellation.checkCancellation()
        let title = arguments.string("title") ?? "Lumina Note"
        let body = arguments.string("body") ?? arguments.string("text") ?? ""
        let filename = Self.sanitizedFilename(arguments.string("filename") ?? title)
        let directory = documentsDirectory.appendingPathComponent("Lumina Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent(filename)
        let markdown = "# \(title)\n\n\(body)\n"
        try markdown.data(using: .utf8)?.write(to: fileURL, options: .atomic)
        return LuminaToolResult(
            callID: UUID(),
            toolName: schema.name,
            status: .succeeded,
            output: [
                "filename": .string(filename),
                "relativePath": .string("Lumina Notes/\(filename)"),
                "byteCount": .number(Double(markdown.utf8.count))
            ],
            content: [.markdown("## 文件已保存\n\n\(filename)")]
        )
    }

    private static func sanitizedFilename(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let stem = String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = stem.isEmpty ? "Lumina-Note" : stem
        return name.hasSuffix(".md") ? name : "\(name).md"
    }
}
