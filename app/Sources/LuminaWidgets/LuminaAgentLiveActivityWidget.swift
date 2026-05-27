import ActivityKit
import LuminaAppCore
import SwiftUI
import WidgetKit

struct LuminaAgentLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LuminaAgentLiveActivityAttributes.self) { context in
            LuminaLiveActivityLockScreenView(context: context)
                .activityBackgroundTint(Color(red: 0.98, green: 0.96, blue: 0.88))
                .activitySystemActionForegroundColor(.black)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    LuminaLiveActivityIcon(progress: context.state.progress)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(context.state.title)
                            .font(.headline.weight(.semibold))
                            .lineLimit(1)
                        Text(context.state.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(Int(context.state.progress * 100))%")
                        .font(.caption.weight(.bold))
                        .monospacedDigit()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.yellow.opacity(0.22), in: Capsule())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ProgressView(value: context.state.progress)
                        .tint(.yellow)
                }
            } compactLeading: {
                Image(systemName: context.state.isLocalOnly ? "sparkles" : "arrow.triangle.2.circlepath")
                    .foregroundStyle(.yellow)
            } compactTrailing: {
                Text("\(Int(context.state.progress * 100))")
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            } minimal: {
                Image(systemName: "sparkles")
                    .foregroundStyle(.yellow)
            }
            .widgetURL(URL(string: "lumina://activity/\(context.attributes.runID)"))
            .keylineTint(.yellow)
        }
    }
}
