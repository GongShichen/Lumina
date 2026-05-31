import Foundation

public enum LuminaRuntimeStateScope: String, Codable, Hashable, Sendable {
    case temp
    case session
    case user
    case app
}

public struct LuminaRuntimeStateMutation: Codable, Hashable, Sendable {
    public var scope: LuminaRuntimeStateScope
    public var key: String
    public var value: LuminaJSONValue?
    public var timestamp: Date

    public init(
        scope: LuminaRuntimeStateScope,
        key: String,
        value: LuminaJSONValue?,
        timestamp: Date = Date()
    ) {
        self.scope = scope
        self.key = key
        self.value = value
        self.timestamp = timestamp
    }
}

public actor LuminaRuntimeState {
    private var temp: [String: LuminaJSONValue] = [:]
    private var session: [String: LuminaJSONValue] = [:]
    private var user: [String: LuminaJSONValue] = [:]
    private var app: [String: LuminaJSONValue] = [:]
    private var mutations: [LuminaRuntimeStateMutation] = []
    private let eventSink: (@Sendable (LuminaRuntimeStateMutation) -> Void)?

    public init(eventSink: (@Sendable (LuminaRuntimeStateMutation) -> Void)? = nil) {
        self.eventSink = eventSink
    }

    public func value(scope: LuminaRuntimeStateScope, key: String) -> LuminaJSONValue? {
        storage(for: scope)[key]
    }

    public func set(_ value: LuminaJSONValue, scope: LuminaRuntimeStateScope, key: String) {
        mutate(scope: scope, key: key, value: value)
    }

    public func remove(scope: LuminaRuntimeStateScope, key: String) {
        mutate(scope: scope, key: key, value: nil)
    }

    public func clear(scope: LuminaRuntimeStateScope) {
        switch scope {
        case .temp: temp.removeAll()
        case .session: session.removeAll()
        case .user: user.removeAll()
        case .app: app.removeAll()
        }
    }

    public func snapshot(scope: LuminaRuntimeStateScope? = nil) -> [String: [String: LuminaJSONValue]] {
        if let scope {
            return [scope.rawValue: storage(for: scope)]
        }
        return [
            LuminaRuntimeStateScope.temp.rawValue: temp,
            LuminaRuntimeStateScope.session.rawValue: session,
            LuminaRuntimeStateScope.user.rawValue: user,
            LuminaRuntimeStateScope.app.rawValue: app
        ]
    }

    public func mutationLog() -> [LuminaRuntimeStateMutation] {
        mutations
    }

    private func mutate(scope: LuminaRuntimeStateScope, key: String, value: LuminaJSONValue?) {
        switch scope {
        case .temp:
            temp[key] = value
        case .session:
            session[key] = value
        case .user:
            user[key] = value
        case .app:
            app[key] = value
        }
        let mutation = LuminaRuntimeStateMutation(scope: scope, key: key, value: value)
        mutations.append(mutation)
        eventSink?(mutation)
    }

    private func storage(for scope: LuminaRuntimeStateScope) -> [String: LuminaJSONValue] {
        switch scope {
        case .temp: temp
        case .session: session
        case .user: user
        case .app: app
        }
    }
}
