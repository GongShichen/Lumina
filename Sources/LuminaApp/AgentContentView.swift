import AgentRuntime
import AVKit
import LuminaMarkdownUI
import SwiftUI
import UniformTypeIdentifiers

struct AgentContentListView: View {
    let content: [AgentContentPart]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(content) { part in
                AgentContentPartView(part: part)
            }
        }
    }
}

struct AgentContentPartView: View {
    let part: AgentContentPart

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
        asset: AgentMediaAsset,
        @ViewBuilder content: (URL) -> Content
    ) -> some View {
        if let url = asset.url {
            content(url)
        } else {
            fileView(asset)
        }
    }

    private func fileView(_ asset: AgentMediaAsset) -> some View {
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

private struct LocalImageView: View {
    let url: URL

    var body: some View {
        #if canImport(UIKit)
        if let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 260)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            Label(url.lastPathComponent, systemImage: "photo")
        }
        #else
        Label(url.lastPathComponent, systemImage: "photo")
        #endif
    }
}

private extension AgentMediaAsset {
    var url: URL? {
        switch location {
        case let .fileURL(value), let .remoteURL(value):
            return URL(string: value)
        case .inlineBase64, .securityScopedBookmarkBase64:
            return nil
        }
    }
}
