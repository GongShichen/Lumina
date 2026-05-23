import AgentRuntime
import LuminaMarkdownUI
import PhotosUI
import PersonalMemory
import SwiftUI
import UniformTypeIdentifiers

struct AgentHomeView: View {
    @EnvironmentObject private var services: AgentAppServices
    @State private var prompt = "查我下一个会议，并提前 10 分钟提醒我"
    @State private var isRunning = false
    @State private var resultText = ""
    @State private var resultContent: [AgentContentPart] = []
    @State private var timelineItems: [AgentRunTimelineItem] = []
    @State private var statsText = "索引准备中"
    @State private var pendingMessage: MessageDraft?
    @State private var attachments: [MultimodalAttachment] = []
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var isFileImporterPresented = false
    @State private var runTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        TextEditor(text: $prompt)
                            .frame(minHeight: 120)
                            .padding(10)
                            .background(.thinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                        attachmentToolbar
                        attachmentStrip

                        Button {
                            if isRunning {
                                cancelRun()
                            } else {
                                runAgent()
                            }
                        } label: {
                            Label(isRunning ? "停止" : "运行 Agent", systemImage: isRunning ? "stop.fill" : "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!isRunning && prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty)

                        if !timelineItems.isEmpty {
                            AgentRunTimelineView(items: timelineItems)
                        }

                        if !resultText.isEmpty {
                            MarkdownView(markdown: resultText)
                        }

                        if !resultContent.isEmpty {
                            AgentContentListView(content: resultContent)
                        }

                        Text(statsText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                }

                Divider()
                PerformanceFooter()
            }
            .navigationTitle("Local Agent")
            .alert(item: Binding(
                get: { services.confirmation.pending },
                set: { services.confirmation.pending = $0 }
            )) { request in
                Alert(
                    title: Text("确认执行"),
                    message: Text(request.reason),
                    primaryButton: .default(Text("执行")) {
                        services.confirmation.resolve(id: request.id, accepted: true)
                    },
                    secondaryButton: .cancel(Text("取消")) {
                        services.confirmation.resolve(id: request.id, accepted: false)
                    }
                )
            }
            .sheet(item: $pendingMessage) { draft in
                MessageComposeSheet(draft: draft)
            }
            .fileImporter(
                isPresented: $isFileImporterPresented,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { result in
                handleFileImport(result)
            }
            .onChange(of: photoSelection) { _, newValue in
                Task {
                    await importPhotos(newValue)
                    photoSelection = []
                }
            }
            .task {
                for await draft in await services.messageDrafts.drafts() {
                    pendingMessage = draft
                }
            }
            .task {
                await refreshStats()
            }
            .onDisappear {
                runTask?.cancel()
            }
        }
    }

    private var attachmentToolbar: some View {
        HStack(spacing: 10) {
            PhotosPicker(
                selection: $photoSelection,
                maxSelectionCount: 6,
                matching: .any(of: [.images, .videos])
            ) {
                Label("照片/视频", systemImage: "photo.on.rectangle")
            }
            .buttonStyle(.bordered)

            Button {
                isFileImporterPresented = true
            } label: {
                Label("文件", systemImage: "paperclip")
            }
            .buttonStyle(.bordered)

            Spacer()

            if !attachments.isEmpty {
                Button {
                    attachments.removeAll()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("清空附件")
            }
        }
    }

    @ViewBuilder
    private var attachmentStrip: some View {
        if !attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(attachments) { attachment in
                        HStack(spacing: 6) {
                            Image(systemName: attachment.iconName)
                            Text(attachment.displayName)
                                .lineLimit(1)
                            Button {
                                attachments.removeAll { $0.id == attachment.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                        }
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(.thinMaterial)
                        .clipShape(Capsule())
                    }
                }
            }
        }
    }

    private func runAgent() {
        isRunning = true
        resultText = ""
        resultContent = []
        timelineItems = []

        let content = makeRequestContent()
        runTask?.cancel()
        runTask = Task {
            for await event in services.runStream(content: content) {
                if Task.isCancelled { break }
                handleRunEvent(event)
            }
            await refreshStats()
            isRunning = false
        }
    }

    private func cancelRun() {
        runTask?.cancel()
        runTask = nil
        isRunning = false
        timelineItems.append(AgentRunTimelineItem(
            title: "用户已停止",
            detail: nil,
            systemImage: "stop.circle",
            status: .warning
        ))
    }

    private func makeRequestContent() -> [AgentContentPart] {
        var content: [AgentContentPart] = []
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPrompt.isEmpty {
            content.append(.text(trimmedPrompt))
        }
        content.append(contentsOf: attachments.map { $0.contentPart() })
        return content
    }

    private func handleRunEvent(_ event: AgentRunEvent) {
        if let item = AgentRunEventPresenter.item(for: event) {
            timelineItems.append(item)
        }

        switch event {
        case let .toolFinished(result):
            resultContent.append(contentsOf: result.content)
        case let .finished(result):
            resultText = render(result)
            resultContent = result.toolResults.flatMap(\.content)
        default:
            break
        }
    }

    private func render(_ result: AgentRunResult) -> String {
        var lines = [
            "## 运行结果",
            "",
            "- **状态**：\(result.status.rawValue)",
            "- **计划**：\(result.plan.summary)",
            String(format: "- **耗时**：总 %.1fms / 规划 %.1fms / 工具 %.1fms", result.timing.totalMilliseconds, result.timing.planningMilliseconds, result.timing.toolExecutionMilliseconds)
        ]
        if !result.toolResults.isEmpty {
            lines.append("")
            lines.append("### 工具调用")
        }
        for toolResult in result.toolResults {
            lines.append("")
            lines.append("- `\(toolResult.toolName)`: **\(toolResult.status.rawValue)**")
            if let error = toolResult.errorMessage {
                lines.append("  - 错误：\(error)")
            }
            if !toolResult.output.isEmpty {
                lines.append("  - 输出：")
                lines.append("")
                lines.append("```json")
                lines.append(String(describing: toolResult.output))
                lines.append("```")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result else { return }
        for url in urls {
            let didStartAccessing = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let localURL = copyIntoTemporaryStorage(url) ?? url
            attachments.append(AttachmentBuilder.make(from: localURL))
        }
    }

    private func copyIntoTemporaryStorage(_ url: URL) -> URL? {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                continue
            }
            let type = item.supportedContentTypes.first ?? .data
            let ext = type.preferredFilenameExtension ?? "bin"
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext)
            do {
                try data.write(to: url, options: .atomic)
                attachments.append(MultimodalAttachment(
                    url: url,
                    filename: url.lastPathComponent,
                    contentTypeIdentifier: type.identifier,
                    byteCount: data.count,
                    summary: type.conforms(to: .image) ? "用户选择的图片" : "用户选择的视频"
                ))
            } catch {
                continue
            }
        }
    }

    private func refreshStats() async {
        let stats = await services.memoryStore.stats()
        statsText = "Memory: \(stats.documentCount) docs / \(stats.chunkCount) chunks / \(stats.embeddedChunkCount) embedded"
    }
}

private struct PerformanceFooter: View {
    var body: some View {
        HStack(spacing: 12) {
            Label("本地检索", systemImage: "bolt.fill")
            Label("可取消", systemImage: "xmark.circle")
            Label("异步索引", systemImage: "arrow.triangle.2.circlepath")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.vertical, 10)
    }
}
