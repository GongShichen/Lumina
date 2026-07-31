import PersonalMemory
import SwiftUI
import UniformTypeIdentifiers

struct KnowledgeBaseScreen: View {
    @ObservedObject var viewModel: KnowledgeBaseViewModel
    @State private var isCreatePresented = false

    var body: some View {
        ZStack {
            LuminaAppBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    metrics
                    searchPanel
                    baseSection(title: "Built-in", subtitle: "随 Lumina 发布的产品知识", bases: viewModel.bundled)
                    baseSection(title: "Imported", subtitle: "由你主动导入、默认仅本地可用", bases: viewModel.imported)
                    failures
                }
                .padding(16)
            }
        }
        .navigationTitle("Knowledge")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.refresh() }
        .sheet(isPresented: $isCreatePresented) {
            KnowledgeImportSheet(viewModel: viewModel)
        }
        .alert("Knowledge", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            LuminaSectionHeader(
                title: "Knowledge",
                subtitle: "产品资料与导入文档独立于 Personal Memory"
            )
            Button {
                isCreatePresented = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 42, height: 42)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("创建知识库")
        }
    }

    private var metrics: some View {
        HStack(spacing: 10) {
            LuminaMetricTile(title: "Bases", value: "\(viewModel.stats.knowledgeBaseCount)", caption: "Total", tint: LuminaTheme.aqua)
            LuminaMetricTile(title: "Documents", value: "\(viewModel.stats.documentCount)", caption: "Local", tint: LuminaTheme.mint)
            LuminaMetricTile(title: "Ready", value: "\(viewModel.stats.embeddedChunkCount)", caption: "\(viewModel.stats.chunkCount) chunks", tint: LuminaTheme.amber)
        }
    }

    private var searchPanel: some View {
        LuminaPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "magnifyingglass")
                    TextField("本地搜索所有已启用知识库", text: $viewModel.query)
                        .textInputAutocapitalization(.never)
                        .onSubmit { Task { await viewModel.search() } }
                    Button("Search") {
                        Task { await viewModel.search() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(LuminaTheme.navy)
                }
                HStack {
                    LuminaStatusPill(title: "Ranking", value: "BM25 + RRF", systemImage: "point.3.filled.connected.trianglepath.dotted", tint: LuminaTheme.mint)
                    LuminaStatusPill(title: "Latency", value: viewModel.latencyText, systemImage: "timer", tint: LuminaTheme.aqua)
                }
                ForEach(viewModel.results.prefix(8), id: \.chunk.id) { result in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(result.chunk.title).font(.headline)
                        Text(result.chunk.summary).font(.callout).foregroundStyle(.secondary)
                        Text("\(result.citation) · \(matchLabel(result.matchedBy))")
                            .font(.caption)
                            .foregroundStyle(LuminaTheme.navy)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func matchLabel(_ kind: LuminaKnowledgeMatchKind) -> String {
        switch kind {
        case .bm25: "BM25"
        case .vector: "Vector"
        case .hybrid: "Hybrid"
        }
    }

    private func baseSection(
        title: String,
        subtitle: String,
        bases: [LuminaKnowledgeBaseDescriptor]
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            LuminaSectionHeader(title: title, subtitle: subtitle)
            if bases.isEmpty {
                Text(title == "Imported" ? "尚未创建用户知识库" : "没有可用的内置知识库")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(bases) { descriptor in
                    NavigationLink {
                        KnowledgeBaseDetailScreen(viewModel: viewModel, baseID: descriptor.id)
                    } label: {
                        KnowledgeBaseRow(
                            descriptor: descriptor,
                            enabledChanged: { enabled in
                                Task { await viewModel.setEnabled(enabled, baseID: descriptor.id) }
                            }
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var failures: some View {
        if !viewModel.loadFailures.isEmpty {
            LuminaPanel {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Index errors").font(.headline)
                    ForEach(viewModel.loadFailures, id: \.self) {
                        Text($0).font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Retry") {
                        Task { await viewModel.retryIndexing() }
                    }
                }
            }
        }
    }
}

private struct KnowledgeBaseRow: View {
    let descriptor: LuminaKnowledgeBaseDescriptor
    let enabledChanged: (Bool) -> Void

    var body: some View {
        LuminaPanel {
            HStack(spacing: 12) {
                Image(systemName: descriptor.origin == .bundled ? "books.vertical.fill" : "doc.text.fill")
                    .foregroundStyle(descriptor.origin == .bundled ? LuminaTheme.aqua : LuminaTheme.amber)
                VStack(alignment: .leading, spacing: 4) {
                    Text(descriptor.title).font(.headline)
                    Text(descriptor.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Text("\(descriptor.documentCount) docs · \(descriptor.chunkCount) chunks · \(descriptor.indexStatus.rawValue)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { descriptor.enabled },
                    set: { value in enabledChanged(value) }
                ))
                .labelsHidden()
            }
        }
    }
}

private struct KnowledgeImportSheet: View {
    @ObservedObject var viewModel: KnowledgeBaseViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var isImporterPresented = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Knowledge base") {
                    TextField("名称", text: $title)
                    Text("支持 Markdown、TXT 和含文本层的 PDF。每个用户知识库默认仅本地模型可用。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let phase = viewModel.importPhase {
                    Section("Status") {
                        Label(phase.rawValue, systemImage: phase == .failed ? "exclamationmark.triangle" : "arrow.triangle.2.circlepath")
                    }
                }
                Button("选择文件并创建") {
                    isImporterPresented = true
                }
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .navigationTitle("Create Knowledge Base")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        importTask?.cancel()
                        dismiss()
                    }
                }
            }
            .fileImporter(
                isPresented: $isImporterPresented,
                allowedContentTypes: [.plainText, .pdf, UTType(filenameExtension: "md") ?? .plainText],
                allowsMultipleSelection: true
            ) { result in
                guard case let .success(urls) = result else { return }
                importTask = Task {
                    await viewModel.create(title: title, fileURLs: urls)
                    if !Task.isCancelled, viewModel.importPhase == .complete {
                        dismiss()
                    }
                }
            }
            .onDisappear {
                if viewModel.importPhase != .complete {
                    importTask?.cancel()
                }
            }
        }
    }

    @State private var importTask: Task<Void, Never>?
}

private struct KnowledgeBaseDetailScreen: View {
    @ObservedObject var viewModel: KnowledgeBaseViewModel
    let baseID: String
    @Environment(\.dismiss) private var dismiss
    @State private var documents: [LuminaKnowledgeDocument] = []
    @State private var isAddImporterPresented = false
    @State private var confirmRemoteAccess = false
    @State private var confirmDelete = false

    private var descriptor: LuminaKnowledgeBaseDescriptor? {
        viewModel.descriptors.first { $0.id == baseID }
    }

    var body: some View {
        List {
            if let descriptor {
                Section {
                    Text(descriptor.summary)
                    LabeledContent("Source", value: descriptor.origin.rawValue)
                    LabeledContent("Version", value: descriptor.version)
                    LabeledContent("Index", value: descriptor.indexStatus.rawValue)
                    LabeledContent("Chunks", value: "\(descriptor.chunkCount)")
                } header: {
                    Text(descriptor.title)
                }

                Section("Access") {
                    Toggle("Enabled", isOn: Binding(
                        get: { descriptor.enabled },
                        set: { value in Task { await viewModel.setEnabled(value, baseID: baseID) } }
                    ))
                    Toggle("允许远程模型使用", isOn: Binding(
                        get: { descriptor.remoteAccess == .allowRemote },
                        set: { value in
                            if value {
                                confirmRemoteAccess = true
                            } else {
                                Task { await viewModel.setRemoteAccess(.localOnly, baseID: baseID) }
                            }
                        }
                    ))
                    Text("开启后，命中的片段可能发送到你配置的远程 API 提供方。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Documents") {
                    ForEach(documents) { document in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(document.title)
                            Text(documentDetails(document))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            if descriptor.origin == .userImported {
                                Button("Delete", role: .destructive) {
                                    Task {
                                        await viewModel.removeDocument(id: document.id, baseID: baseID)
                                        await reloadDocuments()
                                    }
                                }
                            }
                        }
                    }
                    if descriptor.origin == .userImported {
                        Button("添加文件") { isAddImporterPresented = true }
                    }
                }

                Section("Search this base") {
                    TextField("关键词", text: $viewModel.query)
                        .onSubmit { Task { await viewModel.search(baseID: baseID) } }
                    Button("Search") { Task { await viewModel.search(baseID: baseID) } }
                    ForEach(viewModel.results.filter { $0.chunk.knowledgeBaseID == baseID }, id: \.chunk.id) { result in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(result.chunk.title).font(.headline)
                            Text(result.chunk.summary).font(.caption).foregroundStyle(.secondary)
                            Text(result.citation).font(.caption2).foregroundStyle(LuminaTheme.navy)
                        }
                    }
                }

                if descriptor.indexStatus == .failed {
                    Section {
                        Button("Retry indexing") { Task { await viewModel.retryIndexing() } }
                    }
                }
                if descriptor.origin == .userImported {
                    Section {
                        Button("删除知识库", role: .destructive) { confirmDelete = true }
                    }
                }
            }
        }
        .navigationTitle(descriptor?.title ?? "Knowledge")
        .task { await reloadDocuments() }
        .fileImporter(
            isPresented: $isAddImporterPresented,
            allowedContentTypes: [.plainText, .pdf, UTType(filenameExtension: "md") ?? .plainText],
            allowsMultipleSelection: true
        ) { result in
            guard case let .success(urls) = result else { return }
            Task {
                await viewModel.addDocuments(baseID: baseID, fileURLs: urls)
                await reloadDocuments()
            }
        }
        .alert("允许远程模型使用？", isPresented: $confirmRemoteAccess) {
            Button("取消", role: .cancel) {}
            Button("允许") {
                Task { await viewModel.setRemoteAccess(.allowRemote, baseID: baseID) }
            }
        } message: {
            Text("检索命中的文档片段可能发送到你配置的远程 API 提供方。")
        }
        .alert("删除知识库？", isPresented: $confirmDelete) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                Task {
                    await viewModel.deleteBase(id: baseID)
                    dismiss()
                }
            }
        } message: {
            Text("这会删除知识库及其导入文件，无法从 Lumina 恢复。")
        }
    }

    private func reloadDocuments() async {
        documents = await viewModel.documents(for: baseID)
    }

    private func documentDetails(_ document: LuminaKnowledgeDocument) -> String {
        let size = document.pageCount.map { "\($0) pages" }
            ?? "\(document.characterCount) chars"
        return "\(document.mediaType) · \(size) · \(document.importStatus.rawValue)"
    }
}
