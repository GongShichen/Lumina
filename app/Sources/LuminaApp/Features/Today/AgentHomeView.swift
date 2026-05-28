import SwiftUI

struct AgentHomeView: View {
    @StateObject private var viewModel: AgentHomeViewModel
    @Environment(\.scenePhase) private var scenePhase
    private let services: AgentAppServices

    init(services: AgentAppServices) {
        self.services = services
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
                LuminaSettingsScreen(settings: services.remoteInferenceSettings)
            }
            .tag(LuminaTab.settings)
            .tabItem { Label("Settings", systemImage: "gearshape.fill") }

            if LuminaFeatureFlags.showTrustTab {
                NavigationStack {
                    RuntimeStatusScreen(
                        stats: viewModel.stats,
                        modelReadiness: viewModel.modelReadiness,
                        benchmarkSnapshot: viewModel.benchmarkSnapshot,
                        agenticRLSnapshot: viewModel.agenticRLSnapshot,
                        runBenchmark: viewModel.runBenchmark,
                        cancelBenchmark: viewModel.cancelBenchmark,
                        runAgenticRL: viewModel.runAgenticRLTrajectories,
                        cancelAgenticRL: viewModel.cancelAgenticRLTrajectories
                    )
                }
                .tag(LuminaTab.runtime)
                .tabItem { Label("Trust", systemImage: "lock.shield.fill") }
            }
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

private struct LuminaSettingsScreen: View {
    @ObservedObject var settings: LuminaRemoteInferenceSettingsStore
    @State private var baseURL = ""
    @State private var model = ""
    @State private var apiKey = ""
    @State private var revealAPIKey = false
    @State private var saveStatus = ""
    @State private var saveStatusIsError = false

    var body: some View {
        ZStack {
            LuminaAppBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    remotePanel
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 26)
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Settings")
        .onAppear(perform: loadCurrentSettings)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.white, LuminaTheme.ivory, LuminaTheme.softAmber],
                            center: .topLeading,
                            startRadius: 4,
                            endRadius: 42
                        )
                    )
                    .shadow(color: LuminaTheme.amber.opacity(0.28), radius: 18, y: 8)
                Image(systemName: "gearshape.fill")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(LuminaTheme.deepInk)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 3) {
                Text("Inference Settings")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(LuminaTheme.ink)
                Text("留空使用本地模型；三项都填写后使用 OpenAI-compatible 流式 API。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var remotePanel: some View {
        LuminaPanel(padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                LuminaSectionHeader(title: "Remote API", subtitle: "Base URL 使用 /v1 形式，API key 仅保存到 Keychain。")
                settingsField(title: "Base URL", text: $baseURL, prompt: "https://example.com/v1", keyboard: .URL)
                settingsField(title: "Model", text: $model, prompt: "mimo-v2.5-pro", keyboard: .default)
                apiKeyField
                HStack(spacing: 10) {
                    Label(settings.modeDescription, systemImage: settings.currentConfiguration().isComplete ? "cloud.fill" : "desktopcomputer")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !saveStatus.isEmpty {
                        Text(saveStatus)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(saveStatusIsError ? Color.red : LuminaTheme.mint)
                    }
                }
                HStack(spacing: 10) {
                    Button {
                        do {
                            try settings.save(baseURL: baseURL, model: model, apiKey: apiKey)
                            apiKey = ""
                            revealAPIKey = false
                            saveStatusIsError = false
                            saveStatus = settings.currentConfiguration().isComplete ? "API key saved" : "Saved, missing API key"
                        } catch {
                            saveStatusIsError = true
                            saveStatus = error.localizedDescription
                        }
                    } label: {
                        Label("确认", systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(LuminaTheme.deepInk)

                    Button(role: .destructive) {
                        settings.clear()
                        loadCurrentSettings()
                        saveStatusIsError = false
                        saveStatus = "Cleared"
                    } label: {
                        Label("清空", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var apiKeyField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("API Key")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Group {
                    if revealAPIKey {
                        TextField("sk-...", text: $apiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } else {
                        SecureField(settings.hasAPIKey ? "***" : "", text: $apiKey, prompt: Text("***"))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
                Button {
                    revealAPIKey.toggle()
                    if revealAPIKey && apiKey.isEmpty {
                        apiKey = settings.apiKeyForDisplay()
                    }
                } label: {
                    Image(systemName: revealAPIKey ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(revealAPIKey ? "隐藏 API Key" : "显示 API Key")
            }
            .padding(10)
            .background(Color.white.opacity(0.48), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(settings.hasAPIKey ? "API key saved in Keychain" : "API key missing")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(settings.hasAPIKey ? LuminaTheme.mint : .secondary)
        }
    }

    private func settingsField(
        title: String,
        text: Binding<String>,
        prompt: String,
        keyboard: UIKeyboardType
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField(prompt, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(keyboard)
                .padding(10)
                .background(Color.white.opacity(0.48), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func loadCurrentSettings() {
        baseURL = settings.baseURL
        model = settings.model
        apiKey = settings.hasAPIKey ? "" : ""
        revealAPIKey = false
    }
}
