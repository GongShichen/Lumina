import Foundation

enum LuminaModelReadinessState: String, Sendable {
    case loading
    case ready
    case fallbackUsed
    case unavailable
    case failed

    var displayName: String {
        switch self {
        case .loading:
            return "Loading"
        case .ready:
            return "Core ML ready"
        case .fallbackUsed:
            return "Fallback"
        case .unavailable:
            return "Unavailable"
        case .failed:
            return "Failed"
        }
    }
}
