import LuminaAgentRuntime
import Foundation

public struct LuminaAskUserTool: LuminaAgentTool {
    public typealias AskUser = @Sendable (LuminaAskUserRequest) async -> LuminaAskUserResponse

    private let askUser: AskUser

    public init(askUser: @escaping AskUser) {
        self.askUser = askUser
    }

    public var schema: LuminaToolSchema {
        LuminaToolSchema(
            name: "ask_user",
            description: "在信息不足时暂停 agent loop，向用户提出 1-3 个结构化问题并等待回答。",
            parameters: [
                LuminaToolParameterSchema(name: "questions", type: .array, description: "问题数组，每个问题包含 id、header、question、options。"),
                LuminaToolParameterSchema(name: "reason", type: .string, description: "为什么需要用户回答。"),
                LuminaToolParameterSchema(name: "sensitivity", type: .string, description: "问题敏感级别。", required: false),
                LuminaToolParameterSchema(name: "timeoutSeconds", type: .number, description: "可选等待超时时间。", required: false)
            ],
            sideEffect: .readOnly,
            sensitivity: .privateData,
            acceptedInputModalities: [.text, .structuredData],
            outputModalities: [.text, .structuredData]
        )
    }

    public func call(arguments: [String: LuminaJSONValue], cancellation: LuminaCancellationToken) async throws -> LuminaToolResult {
        try cancellation.checkCancellation()
        let request = try Self.parseRequest(arguments)
        let response = await askUser(request)
        try cancellation.checkCancellation()

        let answeredAt = ISO8601DateFormatter().string(from: response.answeredAt)
        let answerObjects = response.answers.map { answer in
            LuminaJSONValue.object([
                "questionID": .string(answer.questionID),
                "choiceID": answer.choiceID.map(LuminaJSONValue.string) ?? .null,
                "value": .string(answer.value),
                "isCustom": .bool(answer.isCustom)
            ])
        }
        let markdown = response.cancelled
            ? "## 已暂停\n\n你选择稍后再说，Lumina 不会继续执行后续动作。"
            : Self.answerMarkdown(response.answers)

        return LuminaToolResult(
            callID: request.id,
            toolName: schema.name,
            status: response.cancelled ? .cancelled : .succeeded,
            output: [
                "answers": .array(answerObjects),
                "cancelled": .bool(response.cancelled),
                "answeredAt": .string(answeredAt)
            ],
            content: [.markdown(markdown)]
        )
    }

    private static func parseRequest(_ arguments: [String: LuminaJSONValue]) throws -> LuminaAskUserRequest {
        guard case let .array(questionValues)? = arguments["questions"] else {
            throw LuminaAskUserToolError.invalidArguments("ask_user 需要 questions 数组。")
        }

        let questions = questionValues.compactMap(parseQuestion)
        guard !questions.isEmpty else {
            throw LuminaAskUserToolError.invalidArguments("ask_user 至少需要一个有效问题。")
        }

        return LuminaAskUserRequest(
            questions: questions,
            reason: arguments.string("reason") ?? "Lumina 需要你补充一点信息后继续。",
            sensitivity: arguments.string("sensitivity") ?? "normal",
            timeoutSeconds: arguments.number("timeoutSeconds")
        )
    }

    private static func parseQuestion(_ value: LuminaJSONValue) -> LuminaAskUserQuestion? {
        guard case let .object(object) = value else { return nil }
        let id = object.string("id") ?? UUID().uuidString
        let header = object.string("header") ?? "问题"
        guard let question = object.string("question"), !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let options: [LuminaAskUserChoice]
        if case let .array(optionValues)? = object["options"] {
            options = optionValues.compactMap(parseChoice)
        } else {
            options = []
        }
        guard options.count >= 2 else { return nil }
        return LuminaAskUserQuestion(
            id: id,
            header: header,
            question: question,
            options: options,
            allowsCustomAnswer: object.bool("allowsCustomAnswer") ?? true
        )
    }

    private static func parseChoice(_ value: LuminaJSONValue) -> LuminaAskUserChoice? {
        guard case let .object(object) = value else { return nil }
        guard let label = object.string("label"), !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return LuminaAskUserChoice(
            id: object.string("id") ?? label,
            label: label,
            description: object.string("description") ?? "",
            recommended: object.bool("recommended") ?? label.contains("Recommended") || label.contains("推荐")
        )
    }

    private static func answerMarkdown(_ answers: [LuminaAskUserAnswer]) -> String {
        var lines = ["## 已收到你的回答", ""]
        for answer in answers {
            lines.append("- \(answer.value)")
        }
        lines.append("")
        lines.append("Lumina 会基于这些选择继续处理。")
        return lines.joined(separator: "\n")
    }
}
