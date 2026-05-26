import LuminaAgentClient
import LuminaMarkdownUI
import PhotosUI
import PersonalMemory
import SwiftUI

struct TrustChip: View {
    let title: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(tint.opacity(0.12), in: Capsule())
    }
}
