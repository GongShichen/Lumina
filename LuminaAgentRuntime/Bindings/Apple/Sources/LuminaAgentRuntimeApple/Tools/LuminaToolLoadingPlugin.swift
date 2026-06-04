import Foundation

public protocol LuminaToolLoadingPlugin: Sendable {
    func handleToolLoading(requestJSON: String) async -> String
}

public struct LuminaDefaultToolLoadingPlugin: LuminaToolLoadingPlugin {
    public init() {}

    public func handleToolLoading(requestJSON: String) async -> String {
        "{}"
    }
}

public struct LuminaDeferredToolMetadata: Codable, Hashable, Sendable {
    public var name: String
    public var description: String
    public var category: String
    public var searchHint: String
    public var aliases: [String]
    public var sideEffect: LuminaToolSideEffect
    public var sensitivity: LuminaToolSensitivity
    public var parameterNames: [String]
    public var alwaysLoad: Bool
    public var deferByDefault: Bool

    public init(
        name: String,
        description: String,
        category: String = "",
        searchHint: String = "",
        aliases: [String] = [],
        sideEffect: LuminaToolSideEffect = .readOnly,
        sensitivity: LuminaToolSensitivity = .normal,
        parameterNames: [String] = [],
        alwaysLoad: Bool = false,
        deferByDefault: Bool = true
    ) {
        self.name = name
        self.description = description
        self.category = category
        self.searchHint = searchHint
        self.aliases = aliases
        self.sideEffect = sideEffect
        self.sensitivity = sensitivity
        self.parameterNames = parameterNames
        self.alwaysLoad = alwaysLoad
        self.deferByDefault = deferByDefault
    }
}
