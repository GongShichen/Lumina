import Foundation

public extension Array where Element == LuminaAgentContentPart {
    var textForModelInput: String {
        compactMap(\.textForModelInput).joined(separator: "\n")
    }

    var modalities: Set<LuminaAgentModality> {
        Set(map(\.modality))
    }
}
