import Foundation

public protocol LuminaContextLoadingPlugin: Sendable {
    func handleContextLoading(requestJSON: String) async -> String
}

public struct LuminaDefaultContextLoadingPlugin: LuminaContextLoadingPlugin {
    public init() {}

    public func handleContextLoading(requestJSON: String) async -> String {
        "{}"
    }
}
