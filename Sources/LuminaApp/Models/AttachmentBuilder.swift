import AgentRuntime
import Foundation
import UniformTypeIdentifiers

enum AttachmentBuilder {
    static func make(from url: URL) -> MultimodalAttachment {
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        let byteCount = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
        return MultimodalAttachment(
            url: url,
            filename: url.lastPathComponent,
            contentTypeIdentifier: type.identifier,
            byteCount: byteCount,
            summary: url.lastPathComponent
        )
    }
}
