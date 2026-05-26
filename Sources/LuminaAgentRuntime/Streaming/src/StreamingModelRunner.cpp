#include "StreamingModelRunner.hpp"

#include <chrono>
#include <sstream>

#include "Json.hpp"
#include "ReAct.hpp"

namespace LuminaAgent {

StreamingModelRunner::StreamingModelRunner(const RuntimeCallbacks &callbacks)
    : callbacks_(callbacks) {}

std::string StreamingModelRunner::generate(const std::string &plannerInput) const {
    const auto started = std::chrono::steady_clock::now();
    callbacks_.emitEvent("model_generation_started", "{\"input_characters\":" + std::to_string(plannerInput.size()) + "}");
    StreamingModelResult result = callbacks_.callStreamingModelWithMetrics(plannerInput);
    const auto finished = std::chrono::steady_clock::now();
    const auto elapsedMs = std::chrono::duration_cast<std::chrono::milliseconds>(finished - started).count();
    const std::string extracted = firstValidReActStepObject(result.text);
    const std::string modelText = extracted.empty() ? result.text : extracted;
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
            ",\"extracted_standard_step\":" + jsonBool(!extracted.empty()) +
            ",\"output_characters\":" + std::to_string(modelText.size()) + "}"
    );
    return modelText;
}

} // namespace LuminaAgent
