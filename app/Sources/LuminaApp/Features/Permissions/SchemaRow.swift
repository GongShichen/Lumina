import LuminaAgentRuntime
import SwiftUI

struct SchemaRow: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(LuminaTheme.amber)
                .frame(width: 24)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .foregroundStyle(LuminaTheme.ink)
                .lineLimit(2)
        }
    }
}
