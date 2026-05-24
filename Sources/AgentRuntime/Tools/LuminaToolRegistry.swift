import Foundation

public actor LuminaToolRegistry {
    private var toolsByName: [String: AnyLuminaAgentTool]

    public init(tools: [AnyLuminaAgentTool] = []) {
        self.toolsByName = Dictionary(uniqueKeysWithValues: tools.map { ($0.schema.name, $0) })
    }

    public func register(_ tool: AnyLuminaAgentTool) {
        toolsByName[tool.schema.name] = tool
    }

    public func unregister(name: String) {
        toolsByName.removeValue(forKey: name)
    }

    public func tools() -> [AnyLuminaAgentTool] {
        toolsByName.values.sorted { $0.schema.name < $1.schema.name }
    }

    public func schemas() -> [LuminaToolSchema] {
        toolsByName.values.map(\.schema).sorted { $0.name < $1.name }
    }
}
