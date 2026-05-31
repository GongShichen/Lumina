import Foundation

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

    public init(
        trace: (any LuminaRuntimeTraceSink)? = nil,
        metrics: (any LuminaRuntimeMetricsSink)? = nil,
        span: (any LuminaRuntimeSpanSink)? = nil
    ) {
        self.trace = trace
        self.metrics = metrics
        self.span = span
    }

    public static let disabled = LuminaRuntimeObservabilitySinks()
}
