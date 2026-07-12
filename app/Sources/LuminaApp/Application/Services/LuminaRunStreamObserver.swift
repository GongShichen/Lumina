import LuminaAgentRuntime
import Foundation

struct LuminaRunStreamObserver {
    private var startedAt: ContinuousClock.Instant?
    private var permissionTimingMark = 0
    private var confirmationStartedAt: ContinuousClock.Instant?
    private var toolStarts: [UUID: ContinuousClock.Instant] = [:]
    private var confirmationWaitMilliseconds = Double(0)
    private var observedToolExecutionMilliseconds = Double(0)
    private var runtimeMetrics = LuminaBenchmarkRuntimeMetrics()

    mutating func start() {
        startedAt = ContinuousClock.now
        permissionTimingMark = LuminaPermissionTimingRecorder.shared.mark()
    }

    mutating func observe(_ event: LuminaAgentRunEvent) {
        switch event {
        case .stepGenerationStarted:
            runtimeMetrics.stepGenerationStartCount += 1
        case let .stepGenerationProgress(progress):
            runtimeMetrics.modelProgressEventCount += 1
            if progress.message.localizedCaseInsensitiveContains("retry") {
                runtimeMetrics.retryCount += 1
            }
        case .resultGenerated:
            runtimeMetrics.resultGeneratedCount += 1
        case .observationCreated:
            runtimeMetrics.observationCount += 1
        case let .hookAnnotated(key, value):
            runtimeMetrics.hookEventCount += 1
            runtimeMetrics.runtimeEventCount += key.hasPrefix("runtime") ? 1 : 0
            classifyToolLoadingEvent(key: key, value: value)
            classifyContextLoadingEvent(key: key, value: value)
            classifyModelGenerationEvent(key: key, value: value)
            classifyRuntimeDiagnostic(key: key, value: value)
        case .confirmationRequired:
            confirmationStartedAt = ContinuousClock.now
        case .confirmationResolved:
            if let confirmationStartedAt {
                confirmationWaitMilliseconds += milliseconds(since: confirmationStartedAt)
                self.confirmationStartedAt = nil
            }
        case let .toolStarted(call):
            toolStarts[call.id] = ContinuousClock.now
        case let .toolFinished(result):
            if let start = toolStarts.removeValue(forKey: result.callID) {
                observedToolExecutionMilliseconds += milliseconds(since: start)
            }
            if result.status != .succeeded {
                runtimeMetrics.toolFailureCount += 1
                classifyDiagnosticText(result.errorMessage ?? result.output.compactModelTraceValue)
            }
        case let .finished(result):
            if result.status == .cancelled {
                runtimeMetrics.cancellationCount += 1
            }
            if result.status != .succeeded {
                classifyDiagnosticText(result.plan.summary)
            }
        default:
            break
        }
    }

    func finish(result: LuminaAgentRunResult?) -> LuminaObservedRunTimings {
        let wallClock = startedAt.map(milliseconds(since:)) ?? 0
        let modelGeneration = result?.timing.stepGenerationMilliseconds ?? 0
        let permissionWait = LuminaPermissionTimingRecorder.shared.milliseconds(after: permissionTimingMark)
        let measuredToolExecution = max(0, observedToolExecutionMilliseconds - permissionWait)
        let active = modelGeneration + measuredToolExecution
        return LuminaObservedRunTimings(
            wallClockMilliseconds: wallClock,
            activeRuntimeMilliseconds: active,
            confirmationWaitMilliseconds: confirmationWaitMilliseconds,
            systemPermissionWaitMilliseconds: permissionWait,
            observedToolExecutionMilliseconds: observedToolExecutionMilliseconds,
            runtimeMetrics: runtimeMetrics
        )
    }

    private mutating func classifyRuntimeDiagnostic(key: String, value: LuminaJSONValue) {
        classifyMultiToolEvent(key: key, value: value)
        classifyDiagnosticText(key)
        classifyDiagnosticText(Self.string(for: value))
    }

    private mutating func classifyMultiToolEvent(key: String, value: LuminaJSONValue) {
        switch key {
        case "runtime_event.internal_tool_ignored":
            runtimeMetrics.internalToolIgnoredCount += 1
        case "runtime_event.multi_tool_use_started":
            guard let payload = Self.runtimePayload(for: value) else { return }
            runtimeMetrics.multiToolCallCount += Self.int(payload["call_count"])
        case "runtime_event.multi_tool_use_call_failed":
            runtimeMetrics.multiToolPartialFailureCount += 1
        case "runtime_event.multi_tool_use_stopped":
            guard let payload = Self.runtimePayload(for: value),
                  payload["reason"] as? String == "side_effect_failure"
            else { return }
            runtimeMetrics.sideEffectBatchStopCount += 1
        default:
            break
        }
    }

    private mutating func classifyToolLoadingEvent(key: String, value: LuminaJSONValue) {
        guard key.hasPrefix("runtime_event.tool_loading") else { return }
        switch key {
        case "runtime_event.tool_loading.catalog_emitted":
            runtimeMetrics.toolLoadingCatalogEmittedCount += 1
        case "runtime_event.tool_loading.search":
            runtimeMetrics.toolLoadingSearchCount += 1
        case "runtime_event.tool_loading.loaded":
            break
        case "runtime_event.tool_loading.load_failed":
            runtimeMetrics.toolLoadingLoadFailedCount += 1
        case "runtime_event.tool_loading.unknown_tool":
            runtimeMetrics.toolLoadingUnknownToolCount += 1
        default:
            break
        }

        guard case let .string(eventJSON) = value,
              let data = eventJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        let outerPayload = object["payload"] as? [String: Any]
        let payload = (outerPayload?["payload"] as? [String: Any]) ?? outerPayload ?? [:]
        if key == "runtime_event.tool_loading.search",
           let matchCount = payload["match_count"] as? Int,
           matchCount > 0 {
            runtimeMetrics.toolLoadingDiscoveryHitCount += 1
        }
        if key == "runtime_event.tool_loading.loaded",
           let loaded = payload["loaded"] as? [Any] {
            runtimeMetrics.toolLoadingLoadedCount += loaded.count
        }
        if key == "runtime_event.tool_loading.catalog_emitted" {
            if let saved = payload["schema_tokens_saved_estimate"] as? Int {
                runtimeMetrics.schemaTokensSavedEstimate += saved
            } else if let saved = payload["schema_tokens_saved_estimate"] as? Double {
                runtimeMetrics.schemaTokensSavedEstimate += Int(saved)
            }
        }
    }

    private mutating func classifyContextLoadingEvent(key: String, value: LuminaJSONValue) {
        guard key.hasPrefix("runtime_event.context_loading") else { return }
        switch key {
        case "runtime_event.context_loading.catalog_emitted":
            runtimeMetrics.contextLoadingCatalogEmittedCount += 1
        case "runtime_event.context_loading.search":
            runtimeMetrics.contextLoadingSearchCount += 1
        case "runtime_event.context_loading.loaded":
            break
        case "runtime_event.context_loading.range_loaded":
            break
        case "runtime_event.context_loading.cache_hit":
            runtimeMetrics.contextLoadingCacheHitCount += 1
        case "runtime_event.context_loading.load_failed":
            runtimeMetrics.contextLoadingLoadFailedCount += 1
        default:
            break
        }

        guard case let .string(eventJSON) = value,
              let data = eventJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        let outerPayload = object["payload"] as? [String: Any]
        let payload = (outerPayload?["payload"] as? [String: Any]) ?? outerPayload ?? [:]
        if let estimate = payload["tokens_estimate"] as? Int {
            runtimeMetrics.contextLoadingTokensEstimate += estimate
        } else if let estimate = payload["tokens_estimate"] as? Double {
            runtimeMetrics.contextLoadingTokensEstimate += Int(estimate)
        }
        let loadedCount: Int
        if let loaded = payload["loaded_count"] as? Int {
            loadedCount = loaded
        } else if let loaded = payload["loaded_count"] as? Double {
            loadedCount = Int(loaded)
        } else {
            loadedCount = 0
        }
        if key == "runtime_event.context_loading.loaded" {
            runtimeMetrics.contextLoadingLoadedCount += loadedCount
        } else if key == "runtime_event.context_loading.range_loaded" {
            runtimeMetrics.contextLoadingRangeLoadedCount += loadedCount
        }
    }

    private mutating func classifyModelGenerationEvent(key: String, value: LuminaJSONValue) {
        guard key == "runtime_event.model_generation_validated" else { return }
        runtimeMetrics.modelGenerationValidatedCount += 1
        guard let payload = Self.runtimePayload(for: value) else { return }

        if Self.bool(payload["model_stream_contains_special_tokens"]) == true {
            runtimeMetrics.modelStreamContainsSpecialTokensCount += 1
        }
        if Self.bool(payload["host_returned_canonical_step"]) == true {
            runtimeMetrics.hostReturnedCanonicalStepCount += 1
        }
        if Self.bool(payload["core_extracted_special_token_step"]) == true {
            runtimeMetrics.coreExtractedSpecialTokenStepCount += 1
        }

        let canonicalExcerpt = payload["canonical_step_excerpt"] as? String ?? ""
        if let canonicalType = Self.canonicalStepType(from: canonicalExcerpt) {
            if canonicalType == "tool_use" {
                runtimeMetrics.canonicalToolUseStepCount += 1
            } else if canonicalType == "multi_tool_use" {
                runtimeMetrics.multiToolGenerationCount += 1
            } else if canonicalType == "result" {
                runtimeMetrics.canonicalResultStepCount += 1
            }
        }

        let callbackExcerpt = payload["model_callback_output_excerpt"] as? String ?? ""
        if Self.containsLegacyOutputSchema(callbackExcerpt) || Self.containsLegacyOutputSchema(canonicalExcerpt) {
            runtimeMetrics.legacyOutputSchemaObservedCount += 1
        }
    }

    private mutating func classifyDiagnosticText(_ text: String) {
        let lowered = text.lowercased()
        if lowered.contains("invalid react") ||
            lowered.contains("parser") ||
            lowered.contains("did not produce valid") ||
            lowered.contains("normalization") ||
            lowered.contains("normalize") {
            runtimeMetrics.normalizationFailureCount += 1
        }
        if lowered.contains("invalid schema") ||
            lowered.contains("missing required") ||
            lowered.contains("schema validation") ||
            lowered.contains("parameter") && lowered.contains("required") {
            runtimeMetrics.schemaValidationFailureCount += 1
        }
        if lowered.contains("observation") &&
            (lowered.contains("model") || lowered.contains("runtime-owned") || lowered.contains("runtime-only")) {
            runtimeMetrics.modelOwnedObservationRejectCount += 1
        }
        if lowered.contains("unknown tool") ||
            lowered.contains("tool is not registered") ||
            lowered.contains("not registered") {
            runtimeMetrics.unknownToolRejectCount += 1
        }
        if lowered.contains("fallback") || lowered.contains("回落") {
            runtimeMetrics.fallbackCount += 1
        }
        if lowered.contains("retry") || lowered.contains("重试") {
            runtimeMetrics.retryCount += 1
        }
    }

    private static func string(for value: LuminaJSONValue) -> String {
        if case let .string(string) = value {
            return string
        }
        return value.compactModelTraceValue
    }

    private static func runtimePayload(for value: LuminaJSONValue) -> [String: Any]? {
        guard case let .string(eventJSON) = value,
              let data = eventJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let outerPayload = object["payload"] as? [String: Any]
        return (outerPayload?["payload"] as? [String: Any]) ?? outerPayload
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let string = value as? String {
            if string == "true" { return true }
            if string == "false" { return false }
        }
        return nil
    }

    private static func int(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value) }
        if let value = value as? String { return Int(value) ?? 0 }
        return 0
    }

    private static func canonicalStepType(from excerpt: String) -> String? {
        guard let data = excerpt.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["type"] as? String
    }

    private static func containsLegacyOutputSchema(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("\"thought\"") ||
            lowered.contains("\"type\":\"tool_response\"") ||
            lowered.contains("\"type\": \"tool_response\"") ||
            lowered.contains("<tool_response") ||
            lowered.contains("<tool_use")
    }

    private func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: ContinuousClock.now)
        return Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
}
