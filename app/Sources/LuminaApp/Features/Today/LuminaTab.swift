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
    case runtime
}

enum LuminaFeatureFlags {
    static let showTrustTab = true
}
