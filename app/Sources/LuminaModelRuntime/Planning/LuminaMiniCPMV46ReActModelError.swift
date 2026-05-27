import Foundation

public enum LuminaMiniCPMV46ReActModelError: LocalizedError {
    case missingBundleFiles([String])
    case unsupportedArchitecture(String)
    case missingJSONObject(String)
    case engineUnavailable(String)
    case contextWindowExhausted(inputTokens: Int, contextLength: Int, safetyMargin: Int)

    public var errorDescription: String? {
        switch self {
        case let .missingBundleFiles(files):
            return "MiniCPM-V 4.6 model bundle is incomplete. Missing: \(files.joined(separator: ", "))"
        case let .unsupportedArchitecture(architecture):
            return "MiniCPM-V 4.6 bundle has unsupported architecture '\(architecture)'. Expected 'minicpm-v-4_6' or 'minicpm'."
        case let .missingJSONObject(output):
            return "MiniCPM-V 4.6 model did not return a ReAct JSON object. Output prefix: \(String(output.prefix(240)))"
        case let .engineUnavailable(message):
            return message
        case let .contextWindowExhausted(inputTokens, contextLength, safetyMargin):
            return "MiniCPM-V 4.6 prompt uses about \(inputTokens) tokens, leaving no safe output budget in context \(contextLength) with safety margin \(safetyMargin). Compact context before running."
        }
    }
}
