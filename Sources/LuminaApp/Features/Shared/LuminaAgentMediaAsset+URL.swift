import LuminaAgentClient
import AVKit
import LuminaMarkdownUI
import SwiftUI
import UniformTypeIdentifiers

extension LuminaAgentMediaAsset {
    var url: URL? {
        switch location {
        case let .fileURL(value), let .remoteURL(value):
            return URL(string: value)
        case .inlineBase64, .securityScopedBookmarkBase64:
            return nil
        }
    }
}
