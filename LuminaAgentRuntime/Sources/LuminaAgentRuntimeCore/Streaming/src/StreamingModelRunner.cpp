#include "StreamingModelRunner.hpp"

#include <chrono>
#include <sstream>

#include "Json.hpp"
#include "ReAct.hpp"

namespace LuminaAgent {

StreamingModelRunner::StreamingModelRunner(const RuntimeCallbacks &callbacks)
    : callbacks_(callbacks) {}

static std::string excerpt(const std::string &text, size_t limit) {
    if (text.size() <= limit) {
        return text;
    }
    return text.substr(0, limit) + "...";
}

std::string StreamingModelRunner::generate(const std::string &plannerInput) const {
    const auto started = std::chrono::steady_clock::now();
    callbacks_.emitEvent("model_generation_started", "{\"input_characters\":" + std::to_string(plannerInput.size()) + "}");
    callbacks_.span("start", "runtime.model.generate", "{\"input_characters\":" + std::to_string(plannerInput.size()) + "}");
    StreamingModelResult result = callbacks_.callStreamingModelWithMetrics(plannerInput);
    const auto finished = std::chrono::steady_clock::now();
    const auto elapsedMs = std::chrono::duration_cast<std::chrono::milliseconds>(finished - started).count();
    std::string validationError;
    const std::string trimmedOutput = trim(result.text);
    const bool trustedAdapterStep = validateReActStepObject(trimmedOutput, true, validationError);
    std::string normalizationError;
    const std::string normalizedTransport = trustedAdapterStep
        ? ""
        : normalizeReActStepText(result.text, "minicpm_v46_tool_calls", normalizationError);
    const std::string canonicalStepText = trustedAdapterStep ? trimmedOutput : (normalizedTransport.empty() ? result.text : normalizedTransport);
    const bool hostReturnedCanonicalStep = trustedAdapterStep;
    const bool coreExtractedSpecialTokenStep = !normalizedTransport.empty();
    const double tokensPerSecond = elapsedMs <= 0
        ? 0.0
        : (static_cast<double>(result.outputTokenCount) * 1000.0 / static_cast<double>(elapsedMs));
    callbacks_.emitEvent(
        "model_generation_validated",
        "{\"wall_time_ms\":" + std::to_string(elapsedMs) +
            ",\"ttft_ms\":" + std::to_string(result.timeToFirstTokenMilliseconds) +
            ",\"output_token_count\":" + std::to_string(result.outputTokenCount) +
            ",\"tokens_per_second\":" + std::to_string(tokensPerSecond) +
            ",\"chunk_count\":" + std::to_string(result.chunkCount) +
            ",\"host_returned_canonical_step\":" + jsonBool(hostReturnedCanonicalStep) +
            ",\"core_extracted_special_token_step\":" + jsonBool(coreExtractedSpecialTokenStep) +
            ",\"model_stream_contains_special_tokens\":" + jsonBool(result.streamContainsSpecialTokens) +
            ",\"transport\":\"minicpm_v46_tool_calls\"" +
            ",\"model_callback_output_excerpt\":" + jsonString(excerpt(result.text, 1600)) +
            ",\"canonical_step_characters\":" + std::to_string(canonicalStepText.size()) +
            ",\"canonical_step_excerpt\":" + jsonString(excerpt(canonicalStepText, 1200)) + "}"
    );
    callbacks_.metric("model_generation_ms", static_cast<double>(elapsedMs), "{\"input_characters\":" + std::to_string(plannerInput.size()) + ",\"canonical_step_characters\":" + std::to_string(canonicalStepText.size()) + "}");
    callbacks_.metric("model_ttft_ms", static_cast<double>(result.timeToFirstTokenMilliseconds), "{\"chunk_count\":" + std::to_string(result.chunkCount) + "}");
    callbacks_.metric("model_tokens_per_second", tokensPerSecond, "{\"output_token_count\":" + std::to_string(result.outputTokenCount) + "}");
    callbacks_.trace(
        "model_generation_validated",
        "{\"wall_time_ms\":" + std::to_string(elapsedMs) +
            ",\"ttft_ms\":" + std::to_string(result.timeToFirstTokenMilliseconds) +
            ",\"host_returned_canonical_step\":" + jsonBool(hostReturnedCanonicalStep) +
            ",\"core_extracted_special_token_step\":" + jsonBool(coreExtractedSpecialTokenStep) +
            ",\"model_stream_contains_special_tokens\":" + jsonBool(result.streamContainsSpecialTokens) +
            ",\"model_callback_output_excerpt\":" + jsonString(excerpt(result.text, 1600)) +
            ",\"canonical_step_excerpt\":" + jsonString(excerpt(canonicalStepText, 1200)) + "}"
    );
    callbacks_.span("end", "runtime.model.generate", "{\"wall_time_ms\":" + std::to_string(elapsedMs) + ",\"canonical_step_characters\":" + std::to_string(canonicalStepText.size()) + "}");
    return canonicalStepText;
}

} // namespace LuminaAgent
