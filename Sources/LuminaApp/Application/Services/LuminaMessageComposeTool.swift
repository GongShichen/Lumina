import AgentRuntime
@preconcurrency import EventKit
import Foundation
import PersonalMemory

struct LuminaMessageComposeTool: LuminaAgentTool {
    let messageDrafts: LuminaMessageDraftCenter

    var schema: LuminaToolSchema {
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

    func call(arguments: [String: LuminaJSONValue], cancellation: LuminaCancellationToken) async throws -> LuminaToolResult {
        try cancellation.checkCancellation()
        #if targetEnvironment(macCatalyst) || os(macOS)
        return LuminaToolResult(
            callID: UUID(),
            toolName: schema.name,
            status: .failed,
            output: [
                "available": .bool(false),
                "platform": .string("macOS")
            ],
            content: [.markdown("## 短信草稿不可用\n\nmacOS 版本不能通过公开系统 API 打开短信编辑器。请在 iPhone 上重试，Lumina 不会静默发送短信。")],
            errorMessage: "macOS 版本不支持系统短信编辑器。"
        )
        #else
        let recipient = arguments.string("recipient").map { [$0] } ?? []
        let body = arguments.string("body") ?? ""
        await messageDrafts.publish(LuminaMessageDraft(recipients: recipient, body: body))
        return LuminaToolResult(
            callID: UUID(),
            toolName: schema.name,
            status: .succeeded,
            output: ["draft": .string("Message composer opened.")],
            content: [.text("短信编辑器已打开，等待用户发送或取消。")]
        )
        #endif
    }
}
