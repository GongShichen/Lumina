import LuminaAgentRuntime
import AVKit
import LuminaMarkdownUI
import SwiftUI
import UniformTypeIdentifiers

struct LocalImageView: View {
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
