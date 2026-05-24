import AgentRuntime
import SwiftUI

struct ToolConfirmationSheet: View {
    let request: ConfirmationRequest
    let resolve: (Bool) -> Void
    @State private var didResolve = false

    var body: some View {
        ZStack {
            LuminaAppBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.largeTitle.weight(.semibold))
                            .foregroundStyle(LuminaTheme.amber)
                            .frame(width: 62, height: 62)
                            .background(LuminaTheme.amber.opacity(0.16), in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Lumina 想先征得你的同意")
                                .font(.title2.weight(.bold))
                            Text("这个动作会改变你的数据。确认前我不会执行。")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }

                    LuminaPanel {
                        VStack(alignment: .leading, spacing: 14) {
                            SchemaRow(title: "想做什么", value: friendlyToolName(request.call.toolName), icon: "wand.and.sparkles")
                            SchemaRow(title: "为什么", value: request.reason, icon: "questionmark.circle")
                            SchemaRow(title: "会用到", value: "本机数据，不上传云端", icon: "lock.iphone")
                            SchemaRow(title: "能否撤销", value: "能撤销的会保留 Undo", icon: "arrow.uturn.backward")
                        }
                    }

                    LuminaPanel {
                        VStack(alignment: .leading, spacing: 10) {
                            LuminaSectionHeader(title: "细节", subtitle: "给你看清楚，再由你决定")
                            ForEach(request.call.arguments.keys.sorted(), id: \.self) { key in
                                HStack(alignment: .top) {
                                    Text(friendlyArgumentName(key))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 88, alignment: .leading)
                                    Text(displayValue(request.call.arguments[key] ?? .null))
                                        .font(.caption)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }

                    HStack(spacing: 12) {
                        Button {
                            resolveOnce(false)
                        } label: {
                            Text("Not now")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(didResolve)

                        Button {
                            resolveOnce(true)
                        } label: {
                            Label("Approve", systemImage: "checkmark")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .tint(LuminaTheme.deepInk)
                        .disabled(didResolve)
                    }
                }
                .padding(18)
            }
        }
    }

    private func friendlyToolName(_ name: String) -> String {
        if name.contains("reminder") { return "创建提醒" }
        if name.contains("calendar") { return "更新日历" }
        if name.contains("ledger") { return "记录账目" }
        if name.contains("message") { return "准备短信草稿" }
        return name
    }

    private func friendlyArgumentName(_ name: String) -> String {
        switch name {
        case "body":
            return "正文"
        case "recipient":
            return "收件人"
        case "title":
            return "标题"
        case "memo":
            return "说明"
        case "amount":
            return "金额"
        case "source":
            return "来源"
        case "query":
            return "查询"
        default:
            return name
        }
    }

    private func displayValue(_ value: LuminaJSONValue) -> String {
        switch value {
        case let .string(string):
            return string
        case let .number(number):
            return number.rounded() == number ? String(Int(number)) : String(number)
        case let .bool(bool):
            return bool ? "是" : "否"
        case let .array(values):
            return values.map(displayValue).joined(separator: "\n")
        case let .object(object):
            return object.keys.sorted().map { key in
                "\(friendlyArgumentName(key)): \(displayValue(object[key] ?? .null))"
            }
            .joined(separator: "\n")
        case .null:
            return "无"
        }
    }

    private func resolveOnce(_ accepted: Bool) {
        guard !didResolve else { return }
        didResolve = true
        resolve(accepted)
    }
}
