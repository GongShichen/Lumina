import Combine
import Foundation

@MainActor
final class LuminaLocalModelSelectionStore: ObservableObject, @unchecked Sendable {
    @Published private(set) var selection: LuminaLocalModelSelection

    private let defaults: UserDefaults
    private let selectionKey = "lumina.localModel.selection"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: selectionKey).flatMap(LuminaLocalModelSelection.init(rawValue:))
        let preferred = stored ?? .original
        // A saved experimental selection must not make an installed local model unusable.
        // Keep the saved preference so it can be used when its bundle is installed later.
        let available = LuminaLocalModelSelection.allCases.filter { candidate in
            guard let directory = candidate.resolvedMiniCPMV46ModelURL() else { return false }
            return FileManager.default.fileExists(atPath: directory.appendingPathComponent("model.gguf").path)
                && FileManager.default.fileExists(atPath: directory.appendingPathComponent("model_config.json").path)
        }
        self.selection = available.contains(preferred) ? preferred : (available.first ?? preferred)
    }

    func currentSelection() -> LuminaLocalModelSelection {
        selection
    }

    func select(_ nextSelection: LuminaLocalModelSelection) {
        guard selection != nextSelection else { return }
        selection = nextSelection
        defaults.set(nextSelection.rawValue, forKey: selectionKey)
    }
}
