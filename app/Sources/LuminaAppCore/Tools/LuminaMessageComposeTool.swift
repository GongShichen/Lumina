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
            outputModalities: [.text, .structuredData]
        )
    }

    public func call(arguments: [String: LuminaJSONValue], cancellation: LuminaCancellationToken) async throws -> LuminaToolResult {
        try cancellation.checkCancellation()
        await messageDrafts.publish(LuminaMessageDraft(
            recipients: arguments.string("recipient").map { [$0] } ?? [],
            body: arguments.string("body") ?? ""
        ))
        return LuminaToolResult(
            callID: UUID(),
            toolName: schema.name,
            status: .succeeded,
            output: ["draft": .string("Message composer opened.")],
            content: [.text("短信编辑器已打开，等待用户发送或取消。")]
        )
    }
}
