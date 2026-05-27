import Foundation
import LuminaAppCore
import UserNotifications

#if !targetEnvironment(macCatalyst) && canImport(ActivityKit)
@preconcurrency import ActivityKit
#endif

@MainActor
final class LuminaAgentActivityCenter {
    #if !targetEnvironment(macCatalyst) && canImport(ActivityKit)
    private var liveActivity: Activity<LuminaAgentLiveActivityAttributes>?
    #endif

    func prepareNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func start(snapshot: LuminaAgentActivitySnapshot) {
        prepareNotifications()
        #if !targetEnvironment(macCatalyst) && canImport(ActivityKit)
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = LuminaAgentLiveActivityAttributes(runID: UUID().uuidString)
        let state = LuminaAgentLiveActivityAttributes.ContentState(
            title: snapshot.title,
            detail: snapshot.detail,
            progress: snapshot.progress,
            isLocalOnly: snapshot.isLocalOnly
        )
        do {
            liveActivity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil)
            )
        } catch {
            liveActivity = nil
        }
        #endif
    }

    func update(snapshot: LuminaAgentActivitySnapshot) {
        #if !targetEnvironment(macCatalyst) && canImport(ActivityKit)
        guard let activity = liveActivity else { return }
        let state = LuminaAgentLiveActivityAttributes.ContentState(
            title: snapshot.title,
            detail: snapshot.detail,
            progress: snapshot.progress,
            isLocalOnly: snapshot.isLocalOnly
        )
        Task {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
        #endif
    }

    func finish(snapshot: LuminaAgentActivitySnapshot, shouldNotify: Bool) {
        #if !targetEnvironment(macCatalyst) && canImport(ActivityKit)
        if let activity = liveActivity {
            let state = LuminaAgentLiveActivityAttributes.ContentState(
                title: snapshot.title,
                detail: snapshot.detail,
                progress: snapshot.progress,
                isLocalOnly: snapshot.isLocalOnly
            )
            self.liveActivity = nil
            Task {
                await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(12)))
            }
        }
        #endif
        if shouldNotify {
            sendCompletionNotification()
        }
    }

    private func sendCompletionNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Lumina 已完成本地执行"
        content.body = "点按查看结果。内容只在 App 内展示。"
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "lumina-agent-run-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
