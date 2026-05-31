import Foundation

public enum LuminaRuntimeObservabilityDetailLevel: String, Codable, Hashable, Sendable {
    case minimal
    case summary
    case debug
}

public enum LuminaRuntimeRedactionLevel: String, Codable, Hashable, Sendable {
    case standard
    case strict
}

public struct LuminaRuntimeObservabilityPolicy: Codable, Hashable, Sendable {
    public var detailLevel: LuminaRuntimeObservabilityDetailLevel
    public var redactionLevel: LuminaRuntimeRedactionLevel
    public var samplingRate: Double
    public var includeModelRawOutputSummary: Bool

    public init(
        detailLevel: LuminaRuntimeObservabilityDetailLevel = .summary,
        redactionLevel: LuminaRuntimeRedactionLevel = .standard,
        samplingRate: Double = 1,
        includeModelRawOutputSummary: Bool = false
    ) {
        self.detailLevel = detailLevel
        self.redactionLevel = redactionLevel
        self.samplingRate = max(0, min(1, samplingRate))
        self.includeModelRawOutputSummary = includeModelRawOutputSummary
    }
}

public protocol LuminaRuntimeTraceSink: Sendable {
    func recordTrace(_ recordJSON: String) async
}

public protocol LuminaRuntimeMetricsSink: Sendable {
    func recordMetric(_ metricJSON: String) async
}

public protocol LuminaRuntimeSpanSink: Sendable {
    func recordSpan(_ spanJSON: String) async
}

public struct LuminaRuntimeObservabilitySinks: Sendable {
    public var trace: (any LuminaRuntimeTraceSink)?
    public var metrics: (any LuminaRuntimeMetricsSink)?
    public var span: (any LuminaRuntimeSpanSink)?
    public var policy: LuminaRuntimeObservabilityPolicy

    public init(
        trace: (any LuminaRuntimeTraceSink)? = nil,
        metrics: (any LuminaRuntimeMetricsSink)? = nil,
        span: (any LuminaRuntimeSpanSink)? = nil,
        policy: LuminaRuntimeObservabilityPolicy = LuminaRuntimeObservabilityPolicy()
    ) {
        self.trace = trace
        self.metrics = metrics
        self.span = span
        self.policy = policy
    }

    public static let disabled = LuminaRuntimeObservabilitySinks()
}
