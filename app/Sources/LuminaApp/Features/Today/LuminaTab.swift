import LuminaAgentRuntime
import LuminaMarkdownUI
import PhotosUI
import PersonalMemory
import SwiftUI
import UniformTypeIdentifiers

enum LuminaTab {
    case agent
    case memory
    case settings
    case runtimeLab
    case runtime
}

enum LuminaFeatureFlags {
    static let showAdvancedTabs = false
    static let showSettingsTab = showAdvancedTabs
    static let showRuntimeTab = showAdvancedTabs
    static let showTrustTab = true
}

extension LuminaTab {
    var isVisible: Bool {
        switch self {
        case .agent, .memory:
            return true
        case .settings:
            return LuminaFeatureFlags.showSettingsTab
        case .runtimeLab:
            return LuminaFeatureFlags.showRuntimeTab
        case .runtime:
            return LuminaFeatureFlags.showTrustTab
        }
    }

    var visibleFallback: LuminaTab {
        isVisible ? self : .agent
    }
}
