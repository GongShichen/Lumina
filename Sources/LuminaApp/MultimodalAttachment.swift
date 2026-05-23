import AgentRuntime
import Foundation
import UniformTypeIdentifiers

struct MultimodalAttachment: Identifiable, Hashable {
    var id = UUID()
    var url: URL
    var filename: String
    var contentTypeIdentifier: String
    var byteCount: Int?
    var summary: String?

    var contentType: UTType {
        UTType(contentTypeIdentifier) ?? .data
    }

    var displayName: String {
        filename.isEmpty ? url.lastPathComponent : filename
    }

    var iconName: String {
        if contentType.conforms(to: .image) { return "photo" }
        if contentType.conforms(to: .movie) { return "film" }
        if contentType.conforms(to: .audio) { return "waveform" }
        return "doc"
    }

    func contentPart() -> AgentContentPart {
        let asset = AgentMediaAsset(
            location: .fileURL(url.absoluteString),
            mimeType: contentType.preferredMIMEType ?? "application/octet-stream",
            filename: filename,
            byteCount: byteCount,
            summary: summary ?? displayName
        )

        if contentType.conforms(to: .image) {
            return .image(asset)
        }
        if contentType.conforms(to: .movie) {
            return .video(asset)
        }
        if contentType.conforms(to: .audio) {
            return .audio(asset)
        }
        return .file(asset)
    }
}

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

