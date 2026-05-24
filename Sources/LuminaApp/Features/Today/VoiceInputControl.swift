import SwiftUI

struct VoiceInputControl: View {
    let state: VoiceInputState
    let liveTranscript: String
    let pendingAttachment: MultimodalAttachment?
    @Binding var transcriptDraft: String
    let action: () -> Void
    let useTranscript: () -> Void
    let retry: () -> Void
    let dismiss: () -> Void

    @State private var recordingStartedAt = Date()
    @State private var isPulsing = false

    var body: some View {
        Group {
            if pendingAttachment != nil {
                transcriptPreview
            } else {
                switch state {
                case .requestingPermission:
                    progressState(title: "Preparing voice input...", caption: "Requesting local speech and microphone access")
                case .recording:
                    recordingState
                case .transcribing:
                    progressState(title: "Turning speech into text...", caption: "ON-DEVICE PROCESSING")
                case .failed(let message):
                    messageState(
                        icon: "exclamationmark.waveform",
                        title: "Voice input paused",
                        message: message,
                        tint: LuminaTheme.rose
                    )
                case .unavailable(let message):
                    messageState(
                        icon: "mic.slash",
                        title: "Voice is unavailable",
                        message: message,
                        tint: LuminaTheme.rose
                    )
                case .idle:
                    EmptyView()
                }
            }
        }
        .onChange(of: state) { _, newState in
            if newState == .recording {
                recordingStartedAt = Date()
                isPulsing = true
            } else {
                isPulsing = false
            }
        }
    }

    private var recordingState: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                privacyBadge("On-device listening", tint: LuminaTheme.mint)
                Spacer()
                TimelineView(.periodic(from: recordingStartedAt, by: 1)) { context in
                    Text(elapsedText(at: context.date))
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(LuminaTheme.deepInk.opacity(0.72))
                        .monospacedDigit()
                }
            }

            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(LuminaTheme.amber.opacity(isPulsing ? 0.18 : 0.08))
                        .frame(width: isPulsing ? 96 : 72, height: isPulsing ? 96 : 72)
                        .blur(radius: 10)
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color.white, LuminaTheme.softAmber, LuminaTheme.amber],
                                center: .topLeading,
                                startRadius: 3,
                                endRadius: 44
                            )
                        )
                        .frame(width: 62, height: 62)
                        .shadow(color: LuminaTheme.amber.opacity(0.42), radius: 20, y: 8)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(LuminaTheme.deepInk)
                }
                .animation(.spring(response: 0.92, dampingFraction: 0.72).repeatForever(autoreverses: true), value: isPulsing)

                VStack(alignment: .leading, spacing: 7) {
                    Text("I'm listening...")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(LuminaTheme.ink)
                    TimelineView(.animation) { context in
                        waveform(at: context.date)
                    }
                    .frame(height: 30)
                    if !liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(liveTranscript)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Button(action: action) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(LuminaTheme.deepInk, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("停止录音")
            }
        }
        .padding(14)
        .background(voiceSurface)
        .transition(.scale(scale: 0.94).combined(with: .opacity))
    }

    private var transcriptPreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                privacyBadge("TRANSCRIPT PREVIEW", tint: LuminaTheme.amber)
                Spacer()
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.72), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭语音预览")
            }

            TextEditor(text: $transcriptDraft)
                .font(.callout)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 72, maxHeight: 112)
                .padding(10)
                .background(Color.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            HStack(spacing: 8) {
                Label(pendingAttachment?.displayName ?? "Audio", systemImage: "waveform")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(LuminaTheme.deepInk.opacity(0.68))
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(LuminaTheme.softAmber.opacity(0.28), in: Capsule())
                Spacer()
                Button("Retry", action: retry)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                Button(action: useTranscript) {
                    Label("Use transcript", systemImage: "check")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(LuminaTheme.amber)
            }
        }
        .padding(14)
        .background(voiceSurface)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func progressState(title: String, caption: String) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(LuminaTheme.amber.opacity(0.18), lineWidth: 7)
                    .frame(width: 52, height: 52)
                ProgressView()
                    .tint(LuminaTheme.amber)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(LuminaTheme.ink)
                privacyBadge(caption, tint: LuminaTheme.mint)
            }
            Spacer()
        }
        .padding(14)
        .background(voiceSurface)
        .transition(.scale(scale: 0.96).combined(with: .opacity))
    }

    private func messageState(icon: String, title: String, message: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.10), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LuminaTheme.ink)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(action: retry) {
                Image(systemName: "arrow.clockwise")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(LuminaTheme.deepInk)
                    .frame(width: 32, height: 32)
                    .background(Color.white.opacity(0.72), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("重试语音输入")
        }
        .padding(14)
        .background(voiceSurface)
    }

    private var voiceSurface: some ShapeStyle {
        LinearGradient(
            colors: [
                Color.white.opacity(0.82),
                LuminaTheme.ivory.opacity(0.66),
                LuminaTheme.mint.opacity(0.10)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func privacyBadge(_ text: String, tint: Color) -> some View {
        Label(text, systemImage: "lock.shield.fill")
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(tint.opacity(0.12), in: Capsule())
    }

    private func waveform(at date: Date) -> some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(0..<13, id: \.self) { index in
                let phase = date.timeIntervalSinceReferenceDate * 4 + Double(index) * 0.62
                let height = 8 + abs(sin(phase)) * 22
                Capsule()
                    .fill(index.isMultiple(of: 3) ? LuminaTheme.amber : LuminaTheme.softAmber)
                    .frame(width: 4, height: height)
                    .opacity(0.52 + abs(sin(phase)) * 0.36)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func elapsedText(at date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(recordingStartedAt)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
