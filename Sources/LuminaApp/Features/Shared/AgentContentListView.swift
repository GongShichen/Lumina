import LuminaAgentClient
import AVKit
import LuminaMarkdownUI
import SwiftUI
import UniformTypeIdentifiers

struct AgentContentListView: View {
    let content: [LuminaAgentContentPart]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(content) { part in
                AgentContentPartView(part: part)
            }
        }
    }
}
