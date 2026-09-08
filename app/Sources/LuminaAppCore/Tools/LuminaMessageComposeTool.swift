import LuminaAgentRuntime
import Foundation
import PersonalMemory

public struct LuminaMessageComposeTool: LuminaAgentTool {
    public let messageDrafts: LuminaMessageDraftCenter

    public init(messageDrafts: LuminaMessageDraftCenter) {
        self.messageDrafts = messageDrafts
    }

    public var schema: LuminaToolSchema {
        LuminaToolSchema(
            name: "message.compose",
            description: "创建短信草稿并打开系统消息编辑器，由用户手动发送或取消。",
            parameters: [
                LuminaToolParameterSchema(name: "recipient", type: .string, description: "收件人。", required: false, sensitive: true),
                LuminaToolParameterSchema(name: "body", type: .string, description: "短信正文。", sensitive: true)
            ],
            sideEffect: .externalCommunication,
            sensitivity: .privateData,
            acceptedInputModalities: [.text, .structuredData],
            outputModalities: [.text, .structuredData],
            requiresUserInteraction: true,
            idempotencyPolicy: "caller_keyed",
            maxResultSize: 1_500
        )
    }

    public func call(arguments: [String: LuminaJSONValue], cancellation: LuminaCancellationToken) async throws -> LuminaToolResult {
        try cancellation.checkCancellation()
        let draft = LuminaMessageDraft(
            recipients: arguments.string("recipient").map { [$0] } ?? [],
            body: arguments.string("body") ?? ""
        )
        let outcome = await messageDrafts.compose(draft)
        try cancellation.checkCancellation()
        let status: LuminaToolResultStatus
        let message: String
        let outcomeName: String
        switch outcome {
        case .sent:
            status = .succeeded
            message = "用户已在系统短信编辑器中发送短信。"
            outcomeName = "sent"
        case .cancelled:
            status = .cancelled
            message = "用户已取消短信编辑，未发送短信。"
            outcomeName = "cancelled"
        case .failed(let reason):
            status = .failed
            message = reason
            outcomeName = "failed"
        }
        return LuminaToolResult(
            callID: draft.id,
            toolName: schema.name,
            status: status,
            output: ["draftID": .string(draft.id.uuidString), "outcome": .string(outcomeName)],
            content: [.text(message)],
            errorMessage: status == .failed ? message : nil
        )
    }
}
