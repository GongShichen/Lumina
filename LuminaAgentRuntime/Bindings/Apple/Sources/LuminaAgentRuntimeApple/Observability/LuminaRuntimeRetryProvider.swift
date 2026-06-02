import Foundation

public struct LuminaRuntimeRetryRequest: Codable, Hashable, Sendable {
    public var sessionID: String
    public var runID: String
    public var stage: String
    public var attempt: Int
    public var maxAttempts: Int
    public var errorCode: String
    public var errorCategory: String
    public var recoverable: Bool
    public var toolName: String
    public var toolSideEffect: String
    public var idempotencyPolicy: String
    public var hasIdempotencyKey: Bool
    public var retryAfterSeconds: Double
    public var elapsedMilliseconds: Double

    public init(
        sessionID: String,
        runID: String,
        stage: String,
        attempt: Int,
        maxAttempts: Int,
        errorCode: String,
        errorCategory: String,
        recoverable: Bool,
        toolName: String = "",
        toolSideEffect: String = "",
        idempotencyPolicy: String = "",
        hasIdempotencyKey: Bool = false,
        retryAfterSeconds: Double = 0,
        elapsedMilliseconds: Double = 0
    ) {
        self.sessionID = sessionID
        self.runID = runID
        self.stage = stage
        self.attempt = attempt
        self.maxAttempts = maxAttempts
        self.errorCode = errorCode
        self.errorCategory = errorCategory
        self.recoverable = recoverable
        self.toolName = toolName
        self.toolSideEffect = toolSideEffect
        self.idempotencyPolicy = idempotencyPolicy
        self.hasIdempotencyKey = hasIdempotencyKey
        self.retryAfterSeconds = retryAfterSeconds
        self.elapsedMilliseconds = elapsedMilliseconds
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case runID = "run_id"
        case stage
        case attempt
        case maxAttempts = "max_attempts"
        case errorCode = "error_code"
        case errorCategory = "error_category"
        case recoverable
        case toolName = "tool_name"
        case toolSideEffect = "tool_side_effect"
        case idempotencyPolicy = "idempotency_policy"
        case hasIdempotencyKey = "has_idempotency_key"
        case retryAfterSeconds = "retry_after_seconds"
        case elapsedMilliseconds = "elapsed_ms"
    }
}

public struct LuminaRuntimeRetryDecision: Codable, Hashable, Sendable {
    public enum Action: String, Codable, Sendable {
        case retry
        case fallback
        case fail
        case proceed
    }

    public var action: Action
    public var delayMilliseconds: Int
    public var reason: String
    public var maxAttemptsOverride: Int

    public init(
        action: Action,
        delayMilliseconds: Int = 0,
        reason: String = "",
        maxAttemptsOverride: Int = 0
    ) {
        self.action = action
        self.delayMilliseconds = delayMilliseconds
        self.reason = reason
        self.maxAttemptsOverride = maxAttemptsOverride
    }

    enum CodingKeys: String, CodingKey {
        case action
        case delayMilliseconds = "delay_ms"
        case reason
        case maxAttemptsOverride = "max_attempts_override"
    }
}

public protocol LuminaRuntimeRetryProvider: Sendable {
    func decideRetry(for request: LuminaRuntimeRetryRequest) async -> LuminaRuntimeRetryDecision
}
