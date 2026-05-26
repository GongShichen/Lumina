import LuminaAgentClient
import Foundation
import UniformTypeIdentifiers

struct MultimodalAttachment: Identifiable, Hashable {
    var id = UUID()
    var url: URL
    var filename: String
    var contentTypeIdentifier: String
    var byteCount: Int?
    var summary: String?
    var transcript: String? = nil

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

    func contentPart() -> LuminaAgentContentPart {
        let asset = LuminaAgentMediaAsset(
            location: .fileURL(url.absoluteString),
            mimeType: contentType.preferredMIMEType ?? "application/octet-stream",
            filename: filename,
            byteCount: byteCount,
            transcript: transcript,
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
