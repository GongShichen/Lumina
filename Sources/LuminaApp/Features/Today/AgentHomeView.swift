import SwiftUI

struct AgentHomeView: View {
    @StateObject private var viewModel: AgentHomeViewModel
    @Environment(\.scenePhase) private var scenePhase

    init(services: AgentAppServices) {
        _viewModel = StateObject(wrappedValue: AgentHomeViewModel(services: services))
    }

    var body: some View {
        TabView(selection: $viewModel.selectedTab) {
            NavigationStack {
                AgentConsoleScreen(
                    prompt: $viewModel.prompt,
                    isRunning: viewModel.isRunning,
                    resultText: viewModel.resultText,
                    resultContent: viewModel.resultContent,
                    timelineItems: viewModel.timelineItems,
                    stats: viewModel.stats,
                    homeContent: viewModel.homeContent,
                    modelReadiness: viewModel.modelReadiness,
                    activitySnapshot: viewModel.activitySnapshot,
                    askUserStatus: viewModel.askUserStatus,
                    runSummary: viewModel.runSummary,
                    attachments: viewModel.attachments,
                    voiceState: viewModel.voiceState,
                    voiceTranscript: viewModel.voiceTranscript,
                    pendingVoiceAttachment: viewModel.pendingVoiceAttachment,
                    voiceTranscriptDraft: $viewModel.voiceTranscriptDraft,
                    photoSelection: $viewModel.photoSelection,
                    isFileImporterPresented: $viewModel.isFileImporterPresented,
                    runAction: viewModel.runAction,
                    rerunWithModel: viewModel.runAction,
                    voiceAction: viewModel.toggleVoiceInput,
                    useVoiceTranscript: viewModel.useVoiceTranscript,
                    retryVoiceInput: viewModel.retryVoiceInput,
                    dismissVoicePreview: viewModel.dismissVoicePreview,
                    clearAttachments: viewModel.clearAttachments,
                    removeAttachment: viewModel.removeAttachment
                )
            }
            .tag(LuminaTab.agent)
            .tabItem { Label("Today", systemImage: "sun.max.fill") }

            NavigationStack {
                PersonalMemoryScreen(viewModel: viewModel.memoryViewModel)
            }
            .tag(LuminaTab.memory)
            .tabItem { Label("Memory", systemImage: "brain.head.profile") }

            NavigationStack {
                AuditLogScreen(timelineItems: viewModel.timelineItems, auditRecords: viewModel.auditRecords)
            }
            .tag(LuminaTab.audit)
            .tabItem { Label("Activity", systemImage: "clock.badge.checkmark") }

            NavigationStack {
                RuntimeStatusScreen(
                    stats: viewModel.stats,
                    modelReadiness: viewModel.modelReadiness,
                    benchmarkSnapshot: viewModel.benchmarkSnapshot,
                    runBenchmark: viewModel.runBenchmark,
                    cancelBenchmark: viewModel.cancelBenchmark
                )
            }
            .tag(LuminaTab.runtime)
            .tabItem { Label("Trust", systemImage: "lock.shield.fill") }
        }
        .tint(LuminaTheme.amber)
        .background(LuminaAppBackground())
        .toolbarBackground(.visible, for: .tabBar)
        .toolbarBackground(.ultraThinMaterial, for: .tabBar)
        .overlay {
            if let request = viewModel.pendingAskUser {
                AskUserOverlay(request: request) { answers in
                    viewModel.submitAskUser(requestID: request.id, answers: answers)
                } cancel: {
                    viewModel.cancelAskUser(requestID: request.id)
                }
            }
        }
        .sheet(item: Binding(
            get: { viewModel.pendingConfirmation },
            set: { viewModel.pendingConfirmation = $0 }
        )) { request in
            ToolConfirmationSheet(request: request) { accepted in
                viewModel.resolveConfirmation(id: request.id, accepted: accepted)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $viewModel.pendingMessage) { draft in
            MessageComposeSheet(draft: draft)
        }
        .fileImporter(
            isPresented: $viewModel.isFileImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            viewModel.handleFileImport(result)
        }
        .onChange(of: viewModel.photoSelection) { _, _ in
            viewModel.importSelectedPhotos()
        }
        .onChange(of: scenePhase) { _, phase in
            viewModel.updateScenePhase(phase)
        }
        .task {
            viewModel.start()
        }
        .onDisappear {
            viewModel.stop()
        }
    }
}
