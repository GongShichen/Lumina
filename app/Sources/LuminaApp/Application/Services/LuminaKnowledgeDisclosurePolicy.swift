import Foundation
import PersonalMemory

@MainActor
final class LuminaKnowledgeDisclosurePolicy: Sendable {
    let remoteSettings: LuminaRemoteInferenceSettingsStore
    private var activeRuns: [UUID: LuminaKnowledgeSearchDestination] = [:]

    init(remoteSettings: LuminaRemoteInferenceSettingsStore) {
        self.remoteSettings = remoteSettings
    }

    func beginRun() -> UUID {
        let id = UUID()
        activeRuns[id] = configuredDestination()
        return id
    }

    func endRun(_ id: UUID) {
        activeRuns[id] = nil
    }

    func destination() -> LuminaKnowledgeSearchDestination {
        if activeRuns.values.contains(.remote) {
            return .remote
        }
        return configuredDestination()
    }

    private func configuredDestination() -> LuminaKnowledgeSearchDestination {
        remoteSettings.shouldTreatRunAsRemoteForDisclosure() ? .remote : .local
    }
}
