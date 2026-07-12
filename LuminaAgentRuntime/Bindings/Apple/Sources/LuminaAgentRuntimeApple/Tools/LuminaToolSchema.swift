import Foundation

public struct LuminaToolSchema: Codable, Hashable, Sendable {
    public var name: String
    public var description: String
    public var version: Int
    public var parameters: [LuminaToolParameterSchema]
    public var sideEffect: LuminaToolSideEffect
    public var sensitivity: LuminaToolSensitivity
    public var acceptedInputModalities: Set<LuminaAgentModality>
    public var outputModalities: Set<LuminaAgentModality>
    public var requiresUserInteraction: Bool
    public var interruptBehavior: String?
    public var idempotencyPolicy: String?
    public var destructive: Bool
    public var concurrencySafe: Bool
    public var maxResultSize: Int?
    public var alwaysLoad: Bool
    public var deferByDefault: Bool
    public var aliases: [String]
    public var deprecatedAliases: [String: String]
    public var requiresConfirmation: Bool

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case version
        case parameters
        case sideEffect
        case sensitivity
        case acceptedInputModalities
        case outputModalities
        case requiresUserInteraction
        case interruptBehavior
        case idempotencyPolicy
        case destructive
        case concurrencySafe
        case maxResultSize
        case alwaysLoad
        case deferByDefault
        case aliases
        case deprecatedAliases
        case requiresConfirmation
    }

    public init(
        name: String,
        description: String,
        version: Int = 1,
        parameters: [LuminaToolParameterSchema],
        sideEffect: LuminaToolSideEffect,
        sensitivity: LuminaToolSensitivity = .normal,
        acceptedInputModalities: Set<LuminaAgentModality> = [.text, .structuredData],
        outputModalities: Set<LuminaAgentModality> = [.text, .structuredData],
        requiresUserInteraction: Bool = false,
        interruptBehavior: String? = nil,
        idempotencyPolicy: String? = nil,
        destructive: Bool = false,
        concurrencySafe: Bool = false,
        maxResultSize: Int? = nil,
        aliases: [String] = [],
        deprecatedAliases: [String: String] = [:],
        requiresConfirmation: Bool = false
    ) {
        self.init(
            name: name,
            description: description,
            version: version,
            parameters: parameters,
            sideEffect: sideEffect,
            sensitivity: sensitivity,
            acceptedInputModalities: acceptedInputModalities,
            outputModalities: outputModalities,
            requiresUserInteraction: requiresUserInteraction,
            interruptBehavior: interruptBehavior,
            idempotencyPolicy: idempotencyPolicy,
            destructive: destructive,
            concurrencySafe: concurrencySafe,
            maxResultSize: maxResultSize,
            alwaysLoad: false,
            deferByDefault: false,
            aliases: aliases,
            deprecatedAliases: deprecatedAliases,
            requiresConfirmation: requiresConfirmation
        )
    }

    public init(
        name: String,
        description: String,
        version: Int = 1,
        parameters: [LuminaToolParameterSchema],
        sideEffect: LuminaToolSideEffect,
        sensitivity: LuminaToolSensitivity = .normal,
        acceptedInputModalities: Set<LuminaAgentModality> = [.text, .structuredData],
        outputModalities: Set<LuminaAgentModality> = [.text, .structuredData],
        requiresUserInteraction: Bool = false,
        interruptBehavior: String? = nil,
        idempotencyPolicy: String? = nil,
        destructive: Bool = false,
        concurrencySafe: Bool = false,
        maxResultSize: Int? = nil,
        alwaysLoad: Bool,
        deferByDefault: Bool,
        aliases: [String] = [],
        deprecatedAliases: [String: String] = [:],
        requiresConfirmation: Bool = false
    ) {
        self.name = name
        self.description = description
        self.version = version
        self.parameters = parameters
        self.sideEffect = sideEffect
        self.sensitivity = sensitivity
        self.acceptedInputModalities = acceptedInputModalities
        self.outputModalities = outputModalities
        self.requiresUserInteraction = requiresUserInteraction
        self.interruptBehavior = interruptBehavior
        self.idempotencyPolicy = idempotencyPolicy
        self.destructive = destructive
        self.concurrencySafe = concurrencySafe
        self.maxResultSize = maxResultSize
        self.alwaysLoad = alwaysLoad
        self.deferByDefault = deferByDefault
        self.aliases = aliases
        self.deprecatedAliases = deprecatedAliases
        self.requiresConfirmation = requiresConfirmation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.description = try container.decode(String.self, forKey: .description)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.parameters = try container.decodeIfPresent([LuminaToolParameterSchema].self, forKey: .parameters) ?? []
        self.sideEffect = try container.decodeIfPresent(LuminaToolSideEffect.self, forKey: .sideEffect) ?? .readOnly
        self.sensitivity = try container.decodeIfPresent(LuminaToolSensitivity.self, forKey: .sensitivity) ?? .normal
        self.acceptedInputModalities = try container.decodeIfPresent(Set<LuminaAgentModality>.self, forKey: .acceptedInputModalities) ?? [.text, .structuredData]
        self.outputModalities = try container.decodeIfPresent(Set<LuminaAgentModality>.self, forKey: .outputModalities) ?? [.text, .structuredData]
        self.requiresUserInteraction = try container.decodeIfPresent(Bool.self, forKey: .requiresUserInteraction) ?? false
        self.interruptBehavior = try container.decodeIfPresent(String.self, forKey: .interruptBehavior)
        self.idempotencyPolicy = try container.decodeIfPresent(String.self, forKey: .idempotencyPolicy)
        self.destructive = try container.decodeIfPresent(Bool.self, forKey: .destructive) ?? false
        self.concurrencySafe = try container.decodeIfPresent(Bool.self, forKey: .concurrencySafe) ?? false
        self.maxResultSize = try container.decodeIfPresent(Int.self, forKey: .maxResultSize)
        self.alwaysLoad = try container.decodeIfPresent(Bool.self, forKey: .alwaysLoad) ?? false
        self.deferByDefault = try container.decodeIfPresent(Bool.self, forKey: .deferByDefault) ?? false
        self.aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
        self.deprecatedAliases = try container.decodeIfPresent([String: String].self, forKey: .deprecatedAliases) ?? [:]
        self.requiresConfirmation = try container.decodeIfPresent(Bool.self, forKey: .requiresConfirmation) ?? false
    }
}
