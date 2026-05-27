import Foundation

enum VoiceInputState: Equatable, Sendable {
    case idle
    case requestingPermission
    case recording
    case transcribing
    case unavailable(String)
    case failed(String)

    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .idle:
            return "语音"
        case .requestingPermission:
            return "请求权限"
        case .recording:
            return "停止录音"
        case .transcribing:
            return "转写中"
        case .unavailable:
            return "不可用"
        case .failed:
            return "失败"
        }
    }
}
