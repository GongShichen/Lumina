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
        self.selection = stored ?? .agenticDPO
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
