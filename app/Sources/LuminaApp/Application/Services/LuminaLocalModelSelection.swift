import Foundation

enum LuminaLocalModelSelection: String, CaseIterable, Identifiable, Sendable {
    case original
    case agenticDPO

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .original:
            "原始 MiniCPM-V 4.6"
        case .agenticDPO:
            "Agentic DPO 微调模型"
        }
    }

    var shortLabel: String {
        switch self {
        case .original:
            "原始"
        case .agenticDPO:
            "微调"
        }
    }

    var bundleDirectoryName: String {
        switch self {
        case .original:
            "MiniCPMV46ReActModel"
        case .agenticDPO:
            "MiniCPMV46ReActModel-AgenticSFTDPO-Q8"
        }
    }
}
