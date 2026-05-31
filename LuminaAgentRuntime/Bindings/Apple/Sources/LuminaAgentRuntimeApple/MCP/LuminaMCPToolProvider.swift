import Foundation

public enum LuminaMCPTransportKind: String, Codable, Hashable, Sendable {
    case stdio
    case http
    case sse
}

public struct LuminaMCPToolDescriptor: Codable, Hashable, Sendable {
    public var name: String
    public var description: String
    public var inputSchema: LuminaJSONValue
    public var sideEffect: LuminaToolSideEffect
    public var sensitivity: LuminaToolSensitivity

    public init(
        name: String,
        description: String,
        inputSchema: LuminaJSONValue = .object([:]),
        sideEffect: LuminaToolSideEffect = .readOnly,
        sensitivity: LuminaToolSensitivity = .normal
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.sideEffect = sideEffect
        self.sensitivity = sensitivity
    }
}

public protocol LuminaMCPTransport: Sendable {
    var kind: LuminaMCPTransportKind { get }
    func listTools() async throws -> [LuminaMCPToolDescriptor]
    func callTool(name: String, arguments: [String: LuminaJSONValue]) async throws -> LuminaToolResult
}

public struct LuminaMCPToolProvider: Sendable {
    public var namespace: String
    public var allowedTools: Set<String>
    public var transport: any LuminaMCPTransport
    public var healthEventSink: (@Sendable (String) -> Void)?

    public init(
        namespace: String = "mcp",
        allowedTools: Set<String> = [],
        transport: any LuminaMCPTransport,
        healthEventSink: (@Sendable (String) -> Void)? = nil
    ) {
        self.namespace = namespace
        self.allowedTools = allowedTools
        self.transport = transport
        self.healthEventSink = healthEventSink
    }

    public func loadTools() async throws -> [AnyLuminaAgentTool] {
        do {
            let descriptors = try await transport.listTools()
            healthEventSink?("mcp.\(transport.kind.rawValue).connected")
            return descriptors
                .filter { allowedTools.isEmpty || allowedTools.contains($0.name) }
                .map(makeTool)
        } catch {
            healthEventSink?("mcp.\(transport.kind.rawValue).failed")
            throw error
        }
    }

    private func makeTool(_ descriptor: LuminaMCPToolDescriptor) -> AnyLuminaAgentTool {
        let toolName = "\(namespace).\(descriptor.name)"
        let schema = LuminaToolSchema(
            name: toolName,
            description: descriptor.description,
            parameters: [],
            sideEffect: descriptor.sideEffect,
            sensitivity: descriptor.sensitivity,
            acceptedInputModalities: [.structuredData, .text],
            outputModalities: [.structuredData, .text]
        )
        return AnyLuminaAgentTool(schema: schema) { arguments, _ in
            var result = try await transport.callTool(name: descriptor.name, arguments: arguments)
            result = LuminaToolResult(
                callID: result.callID,
                toolName: toolName,
                status: result.status,
                output: result.output,
                content: result.content,
                errorMessage: result.errorMessage,
                rollbackToken: result.rollbackToken
            )
            return result
        }
    }
}
