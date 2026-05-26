import LuminaAgentClient
import LuminaMarkdownUI
import PhotosUI
import PersonalMemory
import SwiftUI

struct AgentConsoleScreen: View {
    @Binding var prompt: String
    let isRunning: Bool
    let resultText: String
    let resultContent: [LuminaAgentContentPart]
    let timelineItems: [AgentRunTimelineItem]
    let stats: LuminaMemoryIndexStats
    let homeContent: HomeContent
    let modelReadiness: LuminaModelReadinessSnapshot
    let activitySnapshot: LuminaAgentActivitySnapshot
    let askUserStatus: AskUserStatus?
    let runSummary: LuminaAgentRunSummary?
    let attachments: [MultimodalAttachment]
    let voiceState: VoiceInputState
    let voiceTranscript: String
    let pendingVoiceAttachment: MultimodalAttachment?
    @Binding var voiceTranscriptDraft: String
    @Binding var photoSelection: [PhotosPickerItem]
    @Binding var isFileImporterPresented: Bool
    let runAction: () -> Void
    let rerunWithModel: () -> Void
    let voiceAction: () -> Void
    let useVoiceTranscript: () -> Void
    let retryVoiceInput: () -> Void
    let dismissVoicePreview: () -> Void
    let clearAttachments: () -> Void
    let removeAttachment: (UUID) -> Void

    private var isVoiceExpanded: Bool {
        pendingVoiceAttachment != nil || voiceState != .idle
    }

    var body: some View {
        ZStack {
            LuminaAppBackground()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    heroHeader
                    composer
                    if !homeContent.suggestions.isEmpty {
                        suggestionStrip
                    }
                    if let askUserStatus {
                        askUserStatusPill(askUserStatus)
                    }
                    if !timelineItems.isEmpty || isRunning {
                        AgentExecutionStatusView(snapshot: activitySnapshot, items: timelineItems)
                    }
                    if !resultText.isEmpty || !resultContent.isEmpty || isRunning {
                        AgentReplyPanel(
                            markdown: resultText,
                            content: resultContent,
                            runSummary: runSummary,
                            modelReadiness: modelReadiness,
                            isRunning: isRunning,
                            rerunWithModel: rerunWithModel
                        )
                    }
                    trustPreview
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 26)
            }
            .scrollContentBackground(.hidden)
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var heroHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color.white, LuminaTheme.softAmber, LuminaTheme.amber],
                                center: .topLeading,
                                startRadius: 4,
                                endRadius: 42
                            )
                        )
                        .shadow(color: LuminaTheme.amber.opacity(0.38), radius: 22, y: 10)
                    Image(systemName: "sparkles")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(LuminaTheme.deepInk)
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 3) {
                    Text(homeContent.greetingTitle)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(LuminaTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(homeContent.greetingSubtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var suggestionStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(homeContent.suggestions.prefix(3))) { suggestion in
                    SuggestionButton(title: suggestion.title, icon: suggestion.icon) {
                        prompt = suggestion.prompt
                    }
                }
            }
        }
    }

    private func askUserStatusPill(_ status: AskUserStatus) -> some View {
        HStack(spacing: 10) {
            Image(systemName: status.isWaiting ? "person.crop.circle.badge.questionmark" : "checkmark.circle.fill")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(status.isWaiting ? LuminaTheme.amber : LuminaTheme.mint)
                .frame(width: 32, height: 32)
                .background(Color.white.opacity(0.56), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(status.title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(LuminaTheme.ink)
                Text(status.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(12)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(Color.white.opacity(0.72), lineWidth: 1)
        }
    }

    private var composer: some View {
        LuminaPanel(padding: 14) {
            VStack(alignment: .leading, spacing: 13) {
                TextEditor(text: $prompt)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 76)
                    .padding(8)
                    .background(Color.white.opacity(0.46), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                if isVoiceExpanded {
                    VoiceInputControl(
                        state: voiceState,
                        liveTranscript: voiceTranscript,
                        pendingAttachment: pendingVoiceAttachment,
                        transcriptDraft: $voiceTranscriptDraft,
                        action: voiceAction,
                        useTranscript: useVoiceTranscript,
                        retry: retryVoiceInput,
                        dismiss: dismissVoicePreview
                    )
                }

                Button(action: runAction) {
                    HStack(spacing: 10) {
                        Image(systemName: isRunning ? "stop.fill" : "arrow.up")
                        Text(isRunning ? "停止" : "发送给 Lumina")
                            .fontWeight(.semibold)
                        Spacer()
                        Text(attachments.isEmpty ? "Text" : "Multimodal")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(isRunning ? LuminaTheme.rose : LuminaTheme.deepInk)
                .disabled(!isRunning && prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty)

                attachmentToolbar
                attachmentStrip
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
                Image(systemName: "photo.on.rectangle")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("照片或视频")

            Button {
                isFileImporterPresented = true
            } label: {
                Image(systemName: "paperclip")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("文件")

            Button {
                voiceAction()
            } label: {
                Image(systemName: "waveform")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LuminaTheme.deepInk)
                    .frame(width: 42, height: 42)
                    .background(
                        RadialGradient(
                            colors: [Color.white, LuminaTheme.ivory, LuminaTheme.softAmber.opacity(0.72)],
                            center: .topLeading,
                            startRadius: 2,
                            endRadius: 34
                        ),
                        in: Circle()
                    )
                    .overlay {
                        Circle()
                            .stroke(Color.white.opacity(0.78), lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .disabled(isRunning)
            .accessibilityLabel(voiceState.label)
            .opacity(isVoiceExpanded ? 0.42 : 1)

            if !isVoiceExpanded {
                Text("On-device voice")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if !attachments.isEmpty {
                Button(action: clearAttachments) {
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
                                removeAttachment(attachment.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                        }
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(LuminaTheme.blue.opacity(0.10), in: Capsule())
                    }
                }
            }
        }
    }

    private var trustPreview: some View {
        HStack(spacing: 10) {
            TrustSummaryTile(title: "Memory", value: "\(stats.chunkCount) fragments", icon: "brain.head.profile", tint: LuminaTheme.mint)
            TrustSummaryTile(title: "Model", value: modelReadiness.modelSource, icon: "cpu", tint: LuminaTheme.amber)
            TrustSummaryTile(title: "Control", value: "执行前确认", icon: "hand.raised.fill", tint: LuminaTheme.aqua)
        }
    }
}
