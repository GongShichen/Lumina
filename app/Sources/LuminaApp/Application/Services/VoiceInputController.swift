import Foundation
import UniformTypeIdentifiers

#if canImport(AVFoundation) && canImport(Speech)
import AVFoundation
import Speech
#endif

@MainActor
final class VoiceInputController: NSObject, ObservableObject {
    @Published private(set) var state: VoiceInputState = .idle
    @Published private(set) var transcript = ""
    @Published private(set) var completedAttachment: MultimodalAttachment?

    #if canImport(AVFoundation) && canImport(Speech)
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh_CN"))
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioFile: AVAudioFile?
    private var audioURL: URL?
    #endif

    func toggle() {
        switch state {
        case .recording:
            stopRecording()
        case .requestingPermission, .transcribing:
            break
        default:
            Task { await startRecording() }
        }
    }

    func consumeCompletedAttachment() -> MultimodalAttachment? {
        defer { completedAttachment = nil }
        return completedAttachment
    }

    private func startRecording() async {
        #if canImport(AVFoundation) && canImport(Speech)
        state = .requestingPermission
        transcript = ""
        completedAttachment = nil

        guard await Self.requestSpeechPermission(), await Self.requestMicrophonePermission() else {
            state = .unavailable("需要语音识别和麦克风权限")
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            state = .unavailable("当前设备不可用语音识别")
            return
        }

        do {
            try configureAudioSession()
            let engine = AVAudioEngine()
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = true
            }

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("caf")
            let file = try AVAudioFile(forWriting: url, settings: format.settings)

            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
                request.append(buffer)
                try? self?.audioFile?.write(from: buffer)
            }

            audioEngine = engine
            recognitionRequest = request
            audioFile = file
            audioURL = url
            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    self?.handleRecognition(result: result, error: error)
                }
            }

            engine.prepare()
            try engine.start()
            state = .recording
        } catch {
            cleanupAudio()
            state = .failed(Self.userFacingMessage(for: error))
        }
        #else
        state = .unavailable("当前平台不支持语音输入")
        #endif
    }

    private func stopRecording() {
        #if canImport(AVFoundation) && canImport(Speech)
        state = .transcribing
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        recognitionRequest?.endAudio()
        audioFile = nil
        finalizeAttachmentIfPossible()
        #else
        state = .unavailable("当前平台不支持语音输入")
        #endif
    }

    #if canImport(AVFoundation) && canImport(Speech)
    private func handleRecognition(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            transcript = result.bestTranscription.formattedString
            if result.isFinal {
                finalizeAttachmentIfPossible()
                cleanupAudio()
                state = .idle
            }
        }
        if let error {
            cleanupAudio()
            state = .failed(Self.userFacingMessage(for: error))
        }
    }

    private func finalizeAttachmentIfPossible() {
        guard completedAttachment == nil, let audioURL else { return }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let byteCount = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? NSNumber)?.intValue
        completedAttachment = MultimodalAttachment(
            url: audioURL,
            filename: audioURL.lastPathComponent,
            contentTypeIdentifier: UTType.audio.identifier,
            byteCount: byteCount,
            summary: text.isEmpty ? "用户录制的语音" : text,
            transcript: text.isEmpty ? nil : text
        )
    }

    private func cleanupAudio() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        audioEngine = nil
        audioFile = nil
        audioURL = nil
    }

    nonisolated private static func requestSpeechPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    nonisolated private static func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            if #available(iOS 17.0, macCatalyst 17.0, *) {
                AVAudioApplication.requestRecordPermission { allowed in
                    continuation.resume(returning: allowed)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { allowed in
                    continuation.resume(returning: allowed)
                }
            }
        }
    }

    nonisolated private static func userFacingMessage(for error: Error) -> String {
        let nsError = error as NSError
        let description = nsError.localizedDescription
        if nsError.domain == "kLSRErrorDomain" || description.localizedCaseInsensitiveContains("recognizer") {
            return "当前设备没有可用的本地语音识别资源。你仍然可以继续用文字输入。"
        }
        if description.localizedCaseInsensitiveContains("permission") {
            return "需要语音识别和麦克风权限后才能录音。"
        }
        return "语音输入暂时不可用，请稍后重试。"
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }
    #endif
}
