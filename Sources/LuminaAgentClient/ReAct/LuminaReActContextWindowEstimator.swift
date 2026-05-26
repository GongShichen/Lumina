import Foundation

public enum LuminaReActContextWindowEstimator {
    public static func estimateCharacters(
        request: LuminaAgentRequest,
        schemas: [LuminaToolSchema],
        trace: LuminaReActTrace,
        loadedContext: LuminaRuntimeContext
    ) -> Int {
        request.text.count +
            encodedCharacterCount(schemas) +
            encodedCharacterCount(trace) +
            encodedCharacterCount(loadedContext)
    }

    private static func encodedCharacterCount<T: Encodable>(_ value: T) -> Int {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return 0 }
        return data.count
    }
}
