import PersonalMemory
import SwiftUI

struct MemoryResultRow: View {
    let title: String
    let summary: String
    let source: String
    let score: String
    let sensitivity: LuminaMemorySensitivity

    var body: some View {
        LuminaPanel {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(score)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(LuminaTheme.mint)
                }
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                HStack {
                    Label(source, systemImage: "link")
                    Spacer()
                    Label(sensitivity.rawValue, systemImage: "lock")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }
}
