import LuminaAgentClient
import AVKit
import LuminaMarkdownUI
import SwiftUI
import UniformTypeIdentifiers

struct AgentContentPartView: View {
    let part: LuminaAgentContentPart

    var body: some View {
        switch part {
        case let .text(_, value):
            Text(value)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .markdown(_, value):
            MarkdownView(markdown: value)
        case let .image(asset):
            mediaContainer(asset: asset) { url in
                LocalImageView(url: url)
            }
        case let .audio(asset):
            mediaContainer(asset: asset) { url in
                VStack(alignment: .leading, spacing: 8) {
                    Label(asset.filename ?? "Audio", systemImage: "waveform")
                    VideoPlayer(player: AVPlayer(url: url))
                        .frame(height: 72)
                }
            }
        case let .video(asset):
            mediaContainer(asset: asset) { url in
                VideoPlayer(player: AVPlayer(url: url))
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        case let .file(asset):
            fileView(asset)
        case let .structuredData(_, value):
            Text(String(describing: value))
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func mediaContainer<Content: View>(
        asset: LuminaAgentMediaAsset,
        @ViewBuilder content: (URL) -> Content
    ) -> some View {
        if let url = asset.url {
            content(url)
        } else {
            fileView(asset)
        }
    }

    private func fileView(_ asset: LuminaAgentMediaAsset) -> some View {
        HStack(spacing: 10) {
            Image(systemName: iconName(for: asset.mimeType))
            VStack(alignment: .leading, spacing: 2) {
                Text(asset.filename ?? asset.mimeType)
                    .font(.callout)
                if let summary = asset.summary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func iconName(for mimeType: String) -> String {
        if mimeType.hasPrefix("image/") { return "photo" }
        if mimeType.hasPrefix("video/") { return "film" }
        if mimeType.hasPrefix("audio/") { return "waveform" }
        return "doc"
    }
}
