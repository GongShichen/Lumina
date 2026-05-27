import Foundation
import LuminaModelRuntime

@MainActor
final class LuminaModelInferenceMetricsStore: ObservableObject {
    @Published private(set) var recent: [LuminaModelInferenceMetrics] = []
    private let limit: Int

    init(limit: Int = 200) {
        self.limit = limit
    }

    nonisolated func record(_ metrics: LuminaModelInferenceMetrics) {
        Task { @MainActor in
            recent.append(metrics)
            if recent.count > limit {
                recent.removeFirst(recent.count - limit)
            }
        }
    }

    func mark() -> Int {
        recent.count
    }

    func metrics(after mark: Int) -> [LuminaModelInferenceMetrics] {
        guard mark < recent.count else { return [] }
        return Array(recent.dropFirst(mark))
    }
}
