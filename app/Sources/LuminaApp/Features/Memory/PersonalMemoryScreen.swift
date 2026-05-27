import PersonalMemory
import SwiftUI

struct PersonalMemoryScreen: View {
    @ObservedObject var viewModel: PersonalMemoryViewModel

    var body: some View {
        ZStack {
            LuminaAppBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    metrics
                    searchPanel
                    recentMemories
                }
                .padding(16)
            }

            if viewModel.isDeletePickerPresented || viewModel.pendingDeletion != nil {
                MemoryDeletionSheet(viewModel: viewModel)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .bottom)),
                        removal: .opacity
                    ))
                    .zIndex(10)
            }
        }
        .navigationTitle("Memory")
        .navigationBarTitleDisplayMode(.inline)
        .animation(.spring(response: 0.34, dampingFraction: 0.88), value: viewModel.isDeletePickerPresented)
        .animation(.spring(response: 0.34, dampingFraction: 0.88), value: viewModel.pendingDeletion?.id)
        .task {
            await viewModel.search()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            LuminaSectionHeader(title: "Memory", subtitle: "你的记忆只在这台 iPhone 上被整理和搜索")
            Button {
                viewModel.beginDeletionFlow()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(viewModel.stats.chunkCount == 0 ? .secondary : LuminaTheme.rose)
                    .frame(width: 42, height: 42)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay {
                        Circle()
                            .stroke(Color.white.opacity(0.72), lineWidth: 1)
                    }
                    .shadow(color: Color.black.opacity(0.05), radius: 12, y: 6)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.stats.chunkCount == 0)
            .accessibilityLabel("管理记忆删除")
        }
    }

    private var metrics: some View {
        HStack(spacing: 10) {
            LuminaMetricTile(title: "Sources", value: "\(viewModel.stats.documentCount)", caption: "Local", tint: LuminaTheme.aqua)
            LuminaMetricTile(title: "Memories", value: "\(viewModel.stats.chunkCount)", caption: "Searchable", tint: LuminaTheme.mint)
            LuminaMetricTile(title: "Ready", value: "\(viewModel.stats.embeddedChunkCount)", caption: "Private", tint: LuminaTheme.amber)
        }
    }

    private var searchPanel: some View {
        LuminaPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "magnifyingglass")
                    TextField("搜索记忆、项目或某个细节", text: $viewModel.query)
                        .textInputAutocapitalization(.never)
                    Button("Search") {
                        Task { await viewModel.search() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(LuminaTheme.navy)
                }
                Picker("Sensitivity", selection: $viewModel.selectedSensitivity) {
                    Text("Low").tag(LuminaMemorySensitivity.low)
                    Text("Normal").tag(LuminaMemorySensitivity.normal)
                    Text("Sensitive").tag(LuminaMemorySensitivity.sensitive)
                    Text("Private").tag(LuminaMemorySensitivity.privateData)
                }
                .pickerStyle(.segmented)
                .onChange(of: viewModel.selectedSensitivity) { _, _ in
                    Task { await viewModel.search() }
                }

                HStack {
                    LuminaStatusPill(title: "Latency", value: viewModel.latencyText, systemImage: "timer", tint: LuminaTheme.mint)
                    LuminaStatusPill(title: "Local", value: "Private", systemImage: "lock.iphone", tint: LuminaTheme.aqua)
                }
            }
        }
    }

    private var recentMemories: some View {
        VStack(alignment: .leading, spacing: 10) {
            LuminaSectionHeader(title: "Recent Memories", subtitle: "只展示必要摘要和来源")
            if viewModel.results.isEmpty {
                Text(viewModel.emptyStateText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 18)
            } else {
                ForEach(viewModel.results, id: \.chunk.id) { result in
                    MemoryResultRow(
                        title: result.chunk.title,
                        summary: result.chunk.summary,
                        source: "\(result.chunk.source.kind.rawValue)/\(result.chunk.source.identifier)",
                        score: String(format: "%.2f %@", result.score, result.matchedBy.rawValue),
                        sensitivity: result.chunk.sensitivity
                    )
                }
            }
        }
    }
}
