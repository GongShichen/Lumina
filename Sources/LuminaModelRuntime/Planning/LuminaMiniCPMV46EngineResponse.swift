import Foundation

struct LuminaMiniCPMV46EngineResponse: Sendable {
    var ok: Bool
    var output: String?
    var error: String?
    var backend: String
    var promptTokens: Int
    var outputTokens: Int
    var maxOutputTokens: Int
    var contextLength: Int
    var timeToFirstTokenMilliseconds: Double?
    var generationMilliseconds: Double
    var totalMilliseconds: Double
    var tokensPerSecond: Double

    static func decode(_ json: String) throws -> LuminaMiniCPMV46EngineResponse {
        guard let data = json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LuminaMiniCPMV46ReActModelError.engineUnavailable("MiniCPM-V 4.6 native engine returned malformed metadata.")
        }
        return LuminaMiniCPMV46EngineResponse(
            ok: object.bool("ok") ?? false,
            output: object.string("output"),
            error: object.string("error"),
            backend: object.string("backend") ?? "unknown",
            promptTokens: object.int("promptTokens") ?? 0,
            outputTokens: object.int("outputTokens") ?? 0,
            maxOutputTokens: object.int("maxOutputTokens") ?? 0,
            contextLength: object.int("contextLength") ?? 0,
            timeToFirstTokenMilliseconds: object.double("timeToFirstTokenMilliseconds"),
            generationMilliseconds: object.double("generationMilliseconds") ?? 0,
            totalMilliseconds: object.double("totalMilliseconds") ?? 0,
            tokensPerSecond: object.double("tokensPerSecond") ?? 0
        )
    }
}
