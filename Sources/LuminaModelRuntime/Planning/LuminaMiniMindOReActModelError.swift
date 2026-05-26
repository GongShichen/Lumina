import Foundation

public enum LuminaMiniMindOReActModelError: LocalizedError {
    case missingBundleFiles([String])
    case unsupportedArchitecture(String)
    case missingJSONObject(String)
    case missingTokenIDOutput
    case contextWindowExhausted(inputTokens: Int, contextLength: Int, safetyMargin: Int)
    case generationTimedOut(elapsedMilliseconds: Double, outputTokens: Int, outputPrefix: String)

    public var errorDescription: String? {
        switch self {
        case let .missingBundleFiles(files):
            return "MiniMind-o Core ML bundle is incomplete. Missing: \(files.joined(separator: ", "))"
        case let .unsupportedArchitecture(architecture):
            return "MiniMind-o Core ML bundle has unsupported architecture '\(architecture)'. Expected 'minimind-o' or 'minimind'."
        case let .missingJSONObject(output):
            return "MiniMind-o model did not return a ReAct JSON object. Output prefix: \(String(output.prefix(240)))"
        case .missingTokenIDOutput:
            return "MiniMind-o Core ML model did not expose the required token_id output."
        case let .contextWindowExhausted(inputTokens, contextLength, safetyMargin):
            return "MiniMind-o prompt uses \(inputTokens) tokens, leaving no safe output budget in context \(contextLength) with safety margin \(safetyMargin). Compact context before running."
        case let .generationTimedOut(seconds, outputTokens, outputPrefix):
            return "MiniMind-o generation timed out after \(seconds)s before producing a valid ReAct JSON object. outputTokens=\(outputTokens), outputPrefix=\(String(outputPrefix.prefix(240)))"
        }
    }
}
