import Foundation

#if canImport(CoreML) && canImport(CoreMLLLM) && canImport(Tokenizers)
import CoreML
import CoreMLLLM
import Tokenizers

@available(iOS 18.0, macOS 15.0, *)
public enum LuminaGemma4StatefulPlannerModelError: LocalizedError {
    case missingBundleFiles([String])
    case missingJSONObject(String)
    case contextWindowExhausted(inputTokens: Int, contextLength: Int, safetyMargin: Int)

    public var errorDescription: String? {
        switch self {
        case let .missingBundleFiles(files):
            return "Gemma4 Core ML bundle is incomplete. Missing: \(files.joined(separator: ", "))"
        case let .missingJSONObject(output):
            return "Gemma4 planner did not return a JSON object. Output prefix: \(String(output.prefix(240)))"
        case let .contextWindowExhausted(inputTokens, contextLength, safetyMargin):
            return "Gemma4 prompt uses \(inputTokens) tokens, leaving no safe output budget in context \(contextLength) with safety margin \(safetyMargin). Compact context before running."
        }
    }
}
#endif
