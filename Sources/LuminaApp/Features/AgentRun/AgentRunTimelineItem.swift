import AgentRuntime
import Foundation

struct AgentRunTimelineItem: Identifiable, Hashable {
    var id = UUID()
    var coalescingKey: String?
    var title: String
    var detail: String?
    var systemImage: String
    var status: TimelineStatus

    enum TimelineStatus: String, Hashable {
        case active
        case success
        case warning
        case failure
        case info
    }
}
