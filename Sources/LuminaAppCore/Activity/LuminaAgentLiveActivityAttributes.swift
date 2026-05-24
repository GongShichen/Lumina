import Foundation

#if os(iOS) && !targetEnvironment(macCatalyst) && canImport(ActivityKit)
import ActivityKit

public struct LuminaAgentLiveActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public var title: String
        public var detail: String
        public var progress: Double
        public var isLocalOnly: Bool

        public init(title: String, detail: String, progress: Double, isLocalOnly: Bool) {
            self.title = title
            self.detail = detail
            self.progress = progress
            self.isLocalOnly = isLocalOnly
        }
    }

    public var runID: String

    public init(runID: String) {
        self.runID = runID
    }
}
#endif
