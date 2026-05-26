import Foundation

public struct LuminaRuntimeContextSection: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var summary: String
    public var content: String
    public var source: String
    public var sensitivity: LuminaToolSensitivity
    public var disclosureLevel: Int

    public init(
        id: String,
        title: String,
        summary: String,
        content: String,
        source: String,
        sensitivity: LuminaToolSensitivity = .normal,
        disclosureLevel: Int = 0
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.content = content
        self.source = source
        self.sensitivity = sensitivity
        self.disclosureLevel = disclosureLevel
    }
}
