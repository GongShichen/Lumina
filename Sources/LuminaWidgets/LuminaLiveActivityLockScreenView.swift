import ActivityKit
import LuminaAppCore
import SwiftUI
import WidgetKit

struct LuminaLiveActivityLockScreenView: View {
    let context: ActivityViewContext<LuminaAgentLiveActivityAttributes>

    var body: some View {
        HStack(spacing: 14) {
            LuminaLiveActivityIcon(progress: context.state.progress)
            VStack(alignment: .leading, spacing: 4) {
                Text(context.state.title)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                Text(context.state.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                ProgressView(value: context.state.progress)
                    .tint(.yellow)
                    .padding(.top, 2)
            }
            Spacer(minLength: 8)
            Image(systemName: context.state.isLocalOnly ? "lock.shield" : "network")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.cyan)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
    }
}
