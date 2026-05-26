import LuminaAgentClient
import LuminaMarkdownUI
import PhotosUI
import PersonalMemory
import SwiftUI

struct SuggestionButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(LuminaTheme.amber)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LuminaTheme.ink)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Color.white.opacity(0.68), in: Capsule())
            .overlay {
                Capsule().stroke(Color.white.opacity(0.85), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}
