import Foundation

public extension Array where Element == LuminaAgentContentPart {
    var textForPlanning: String {
        compactMap(\.textForPlanning).joined(separator: "\n")
    }

    var modalities: Set<LuminaAgentModality> {
        Set(map(\.modality))
    }
}
