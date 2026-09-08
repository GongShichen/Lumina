#include "llama.h"
#include "ggml-backend.h"

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <limits>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace {

std::mutex g_mutex;
llama_model * g_model = nullptr;
std::string g_loaded_model_path;
std::string g_loaded_backend;
bool g_backend_initialized = false;

struct RequestCancellation {
    bool (*callback)(void *);
    void * context;

    bool cancelled() const { return callback != nullptr && callback(context); }
    static bool abort(void *value) {
        return static_cast<RequestCancellation *>(value)->cancelled();
    }
};

void cleanup_backend() {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_model != nullptr) {
        llama_model_free(g_model);
        g_model = nullptr;
        g_loaded_model_path.clear();
        g_loaded_backend.clear();
    }
    if (g_backend_initialized) {
        llama_backend_free();
        g_backend_initialized = false;
    }
}

void register_backend_cleanup() {
    struct BackendLifetime {
        ~BackendLifetime() { cleanup_backend(); }
    };
    // Construct only after llama has initialized its registry and the model's
    // buffer types. Function statics are destroyed in reverse registration
    // order, so cached Metal weights are released before their device/buffer
    // registries. An early namespace-scope guard would have the wrong order.
    static BackendLifetime lifetime;
    (void) lifetime;
}

std::string escape_json(const std::string & value) {
    std::string escaped;
    escaped.reserve(value.size() + 16);
    for (unsigned char c : value) {
        switch (c) {
        case '"': escaped += "\\\""; break;
        case '\\': escaped += "\\\\"; break;
        case '\b': escaped += "\\b"; break;
        case '\f': escaped += "\\f"; break;
        case '\n': escaped += "\\n"; break;
        case '\r': escaped += "\\r"; break;
        case '\t': escaped += "\\t"; break;
        default:
            if (c < 0x20) {
                const char * hex = "0123456789abcdef";
                escaped += "\\u00";
                escaped += hex[(c >> 4) & 0x0F];
                escaped += hex[c & 0x0F];
            } else {
                escaped += static_cast<char>(c);
            }
        }
    }
    return escaped;
}

char * copy_c_string(const std::string & value) {
    auto * buffer = static_cast<char *>(std::malloc(value.size() + 1));
    if (buffer == nullptr) {
        return nullptr;
    }
    std::memcpy(buffer, value.c_str(), value.size() + 1);
    return buffer;
}

std::string make_response(
    bool ok,
    const std::string & backend,
    int prompt_tokens,
    int output_tokens,
    int max_output_tokens,
    int context_length,
    double ttft_ms,
    double generation_ms,
    double total_ms,
    const std::string & output,
    const std::string & error,
    bool schema_step
) {
    std::ostringstream json;
    json << "{";
    json << "\"ok\":" << (ok ? "true" : "false") << ",";
    json << "\"backend\":\"" << escape_json(backend) << "\",";
    json << "\"promptTokens\":" << prompt_tokens << ",";
    json << "\"outputTokens\":" << output_tokens << ",";
    json << "\"maxOutputTokens\":" << max_output_tokens << ",";
    json << "\"contextLength\":" << context_length << ",";
    json << "\"schemaStep\":" << (schema_step ? "true" : "false") << ",";
    if (ttft_ms >= 0) {
        json << "\"timeToFirstTokenMilliseconds\":" << ttft_ms << ",";
    } else {
        json << "\"timeToFirstTokenMilliseconds\":null,";
    }
    json << "\"generationMilliseconds\":" << generation_ms << ",";
    json << "\"totalMilliseconds\":" << total_ms << ",";
    json << "\"tokensPerSecond\":" << (generation_ms > 0 ? (output_tokens * 1000.0 / generation_ms) : 0.0);
    if (ok) {
        json << ",\"output\":\"" << escape_json(output) << "\"";
    } else {
        json << ",\"error\":\"" << escape_json(error) << "\"";
    }
    json << "}";
    return json.str();
}

std::string model_path_for_directory(const char * model_directory) {
    std::filesystem::path root(model_directory == nullptr ? "" : model_directory);
    std::filesystem::path model = root / "model.gguf";
    std::error_code error;
    if (std::filesystem::is_regular_file(model, error)) {
        return model.string();
    }
    for (const auto & entry : std::filesystem::directory_iterator(root, error)) {
        if (entry.path().extension() == ".gguf" &&
            entry.path().filename().string().find("mmproj") == std::string::npos) {
            return entry.path().string();
        }
    }
    return "";
}

void llama_log_callback(enum ggml_log_level level, const char * text, void * user_data) {
    (void) level;
    (void) user_data;
    printf("[Lumina][llama.cpp] %s", text);
    fflush(stdout);
}

template <typename Params>
auto configure_mmap(Params & params, int) -> decltype(params.use_mmap = true, params.use_mlock = false, void()) {
    params.use_mmap = true;
    params.use_mlock = false;
}

template <typename Params>
void configure_mmap(Params &, long) {
    // Recent llama.cpp versions select the loading strategy through their defaults.
}

bool ensure_model_loaded(const std::string & model_path, RequestCancellation & cancellation, std::string & error) {
    if (g_model != nullptr && g_loaded_model_path == model_path) {
        return true;
    }
    if (g_model != nullptr) {
        llama_model_free(g_model);
        g_model = nullptr;
        g_loaded_model_path.clear();
    }
    if (!g_backend_initialized) {
        llama_log_set(llama_log_callback, nullptr);
        ggml_backend_load_all();
        llama_backend_init();
        g_backend_initialized = true;
    }

    llama_model_params model_params = llama_model_default_params();
    const bool has_gpu = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_GPU) != nullptr;
    model_params.n_gpu_layers = has_gpu ? 999 : 0;
    model_params.progress_callback = [](float, void *state) {
        return !static_cast<RequestCancellation *>(state)->cancelled();
    };
    model_params.progress_callback_user_data = &cancellation;
    configure_mmap(model_params, 0);
    model_params.check_tensors = false;

    g_model = llama_model_load_from_file(model_path.c_str(), model_params);
    register_backend_cleanup();
    if (g_model == nullptr) {
        error = "Failed to load MiniCPM-V GGUF model at " + model_path;
        return false;
    }
    g_loaded_model_path = model_path;
    g_loaded_backend = has_gpu ? "mps" : "cpu";
    return true;
}

std::string chat_wrapped_prompt(const std::string & prompt) {
    if (prompt.find("<|im_start|>") != std::string::npos) {
        return prompt;
    }
    return "<|im_start|>user\n" + prompt + "\n<|im_end|>\n"
           "<|im_start|>assistant\n";
}

std::vector<llama_token> tokenize(const llama_vocab * vocab, const std::string & text, bool add_special, std::string & error) {
    int32_t count = llama_tokenize(vocab, text.c_str(), static_cast<int32_t>(text.size()), nullptr, 0, add_special, true);
    if (count == 0) {
        error = "Tokenizer returned zero tokens.";
        return {};
    }
    if (count < 0) {
        count = -count;
    }
    std::vector<llama_token> tokens(static_cast<size_t>(count));
    int32_t actual = llama_tokenize(vocab, text.c_str(), static_cast<int32_t>(text.size()), tokens.data(), count, add_special, true);
    if (actual < 0) {
        error = "Failed to tokenize MiniCPM-V prompt.";
        return {};
    }
    tokens.resize(static_cast<size_t>(actual));
    return tokens;
}

std::string token_piece(const llama_vocab * vocab, llama_token token) {
    char buffer[512];
    int32_t n = llama_token_to_piece(vocab, token, buffer, sizeof(buffer), 0, false);
    if (n < 0) {
        std::vector<char> piece(static_cast<size_t>(-n));
        n = llama_token_to_piece(vocab, token, piece.data(), static_cast<int32_t>(piece.size()), 0, false);
        return n < 0 ? "" : std::string(piece.data(), static_cast<size_t>(n));
    }
    return std::string(buffer, static_cast<size_t>(n));
}

bool is_minicpm_react_generation(const std::string & prompt) {
    return prompt.find("minicpm_v46_tool_calls") != std::string::npos ||
           prompt.find("<tool_call>") != std::string::npos ||
           prompt.find("<function=") != std::string::npos;
}

bool contains_complete_minicpm_tool_call(const std::string & text) {
    const size_t open = text.find("<tool_call>");
    return open != std::string::npos && text.find("</tool_call>", open) != std::string::npos;
}

} // namespace

extern "C" char * LuminaMiniCPMV46ExternalGenerateReActJSONCancellable(
    const char * model_directory,
    const char * backend_preference,
    const char * prompt,
    int context_length,
    int max_output_tokens,
    int safety_margin_tokens,
    bool (*is_cancelled)(void *),
    void * cancellation_context
) {
    auto start = std::chrono::steady_clock::now();
    RequestCancellation cancellation{is_cancelled, cancellation_context};
    std::lock_guard<std::mutex> lock(g_mutex);
    const std::string preference = backend_preference == nullptr ? "automatic" : backend_preference;
    std::string backend = "unavailable";
    const std::string raw_prompt = prompt == nullptr ? "" : prompt;
    const bool react_transport_step = is_minicpm_react_generation(raw_prompt);
    int prompt_token_count = 0;
    int output_tokens = 0;
    int effective_max_output_tokens = 0;
    double ttft_ms = -1;
    const auto failure = [&](const std::string &error, double generation_ms = 0) {
        const double total_ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - start).count();
        return copy_c_string(make_response(false, backend, prompt_token_count,
            output_tokens, effective_max_output_tokens, context_length, ttft_ms,
            generation_ms, total_ms, "", error, react_transport_step));
    };
    if (cancellation.cancelled()) {
        return failure("MiniCPM-V generation cancelled.");
    }
    if (preference == "ane") {
        return failure("ANE is unavailable: this GGUF engine uses Metal or CPU and has no Core ML partition.");
    }
    if (context_length <= 0 || max_output_tokens <= 0 || safety_margin_tokens < 0) {
        return failure("Context length and output budget must be positive; safety margin must be nonnegative.");
    }
    const std::string model_path = model_path_for_directory(model_directory);
    if (model_path.empty()) {
        return failure("MiniCPM-V model.gguf was not found.");
    }
    std::string error;
    if (!ensure_model_loaded(model_path, cancellation, error)) {
        return failure(cancellation.cancelled() ? "MiniCPM-V generation cancelled during model loading." : error);
    }
    backend = g_loaded_backend;
    if ((preference == "mps" || preference == "metal") && backend != "mps") {
        return failure("Metal was requested but no GPU backend is available.");
    }
    if (cancellation.cancelled()) {
        return failure("MiniCPM-V generation cancelled.");
    }
    const llama_vocab * vocab = llama_model_get_vocab(g_model);
    const std::string prompt_text = chat_wrapped_prompt(raw_prompt);
    const bool prompt_has_chat_template = prompt_text.find("<|im_start|>") != std::string::npos;
    std::vector<llama_token> prompt_tokens = tokenize(vocab, prompt_text, !prompt_has_chat_template, error);
    if (prompt_tokens.empty()) {
        return failure(error);
    }
    prompt_token_count = static_cast<int>(prompt_tokens.size());
    // Use the actual tokenizer count, never an estimate or a minimum output
    // allowance that can exceed the remaining context or caller's token cap.
    const int64_t remaining = static_cast<int64_t>(context_length) - prompt_token_count - safety_margin_tokens;
    if (remaining <= 0) {
        return failure("MiniCPM-V context window exhausted: promptTokens=" + std::to_string(prompt_token_count)
            + ", contextLength=" + std::to_string(context_length)
            + ", safetyMarginTokens=" + std::to_string(safety_margin_tokens)
            + ". Compact context before decoding.");
    }
    effective_max_output_tokens = static_cast<int>(std::min<int64_t>(max_output_tokens, remaining));
    if (react_transport_step) {
        effective_max_output_tokens = std::min(effective_max_output_tokens, 768);
    }
    const int active_context_length = static_cast<int>(std::min<int64_t>(context_length,
        std::max<int64_t>(512, static_cast<int64_t>(prompt_token_count) + effective_max_output_tokens + safety_margin_tokens)));

    llama_context_params ctx_params = llama_context_default_params();
    ctx_params.n_ctx = static_cast<uint32_t>(active_context_length);
    // Both the logical prefill batch and its scratch allocation stay bounded.
    // Metal cannot abort a submitted graph, so checking between batches limits
    // cancellation latency to one 256-token prefill or one decoding step.
    ctx_params.n_batch = static_cast<uint32_t>(std::min(256, active_context_length));
    ctx_params.n_ubatch = ctx_params.n_batch;
    ctx_params.n_threads = std::max(2u, std::thread::hardware_concurrency() / 2);
    ctx_params.n_threads_batch = std::max(2u, std::thread::hardware_concurrency());
    ctx_params.no_perf = false;
    ctx_params.offload_kqv = true;
    ctx_params.op_offload = true;
    ctx_params.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO;
    ctx_params.abort_callback = RequestCancellation::abort;
    ctx_params.abort_callback_data = &cancellation;

    llama_context * ctx = llama_init_from_model(g_model, ctx_params);
    if (ctx == nullptr) {
        return failure("Failed to create MiniCPM-V llama context.");
    }
    llama_sampler_chain_params sampler_params = llama_sampler_chain_default_params();
    sampler_params.no_perf = false;
    llama_sampler * sampler = llama_sampler_chain_init(sampler_params);
    llama_sampler_chain_add(sampler, llama_sampler_init_greedy());
    const auto release = [&] {
        llama_sampler_free(sampler);
        llama_free(ctx);
    };

    for (size_t offset = 0; offset < prompt_tokens.size(); offset += ctx_params.n_batch) {
        if (cancellation.cancelled()) {
            release();
            return failure("MiniCPM-V generation cancelled during prompt decoding.");
        }
        const int32_t count = static_cast<int32_t>(std::min<size_t>(ctx_params.n_batch, prompt_tokens.size() - offset));
        llama_batch batch = llama_batch_get_one(prompt_tokens.data() + offset, count);
        const int32_t decode_result = llama_decode(ctx, batch);
        if (decode_result != 0 || cancellation.cancelled()) {
            release();
            return failure(cancellation.cancelled()
                ? "MiniCPM-V generation cancelled during prompt decoding."
                : "MiniCPM-V prompt decode failed with code " + std::to_string(decode_result) + ".");
        }
    }

    std::string output;
    bool completed = false;
    auto generation_start = std::chrono::steady_clock::now();
    for (int i = 0; i < effective_max_output_tokens; ++i) {
        if (cancellation.cancelled()) {
            error = "MiniCPM-V generation cancelled during decoding.";
            break;
        }
        llama_token token = llama_sampler_sample(sampler, ctx, -1);
        if (llama_vocab_is_eog(vocab, token)) {
            completed = true;
            break;
        }
        llama_sampler_accept(sampler, token);
        if (output_tokens == 0) {
            ttft_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
        }
        output += token_piece(vocab, token);
        output_tokens += 1;
        if ((react_transport_step && contains_complete_minicpm_tool_call(output)) ||
            output.find("<|im_end|>") != std::string::npos) {
            completed = true;
            break;
        }
        // Do not decode the final token when no subsequent sample is allowed.
        if (i + 1 == effective_max_output_tokens) {
            break;
        }
        llama_batch batch = llama_batch_get_one(&token, 1);
        const int32_t decode_result = llama_decode(ctx, batch);
        if (decode_result != 0) {
            error = cancellation.cancelled()
                ? "MiniCPM-V generation cancelled during decoding."
                : "MiniCPM-V token decode failed with code " + std::to_string(decode_result) + ".";
            break;
        }
    }
    auto end = std::chrono::steady_clock::now();
    double generation_ms = std::chrono::duration<double, std::milli>(end - generation_start).count();
    double total_ms = std::chrono::duration<double, std::milli>(end - start).count();
    release();
    if (cancellation.cancelled()) {
        return failure("MiniCPM-V generation cancelled; output discarded.", generation_ms);
    }
    if (!error.empty()) {
        return failure(error, generation_ms);
    }
    if (!completed) {
        return failure("MiniCPM-V output token budget exhausted before a complete response; partial output discarded.", generation_ms);
    }
    return copy_c_string(make_response(true, backend, prompt_token_count, output_tokens,
        effective_max_output_tokens, context_length, ttft_ms, generation_ms, total_ms, output, "", react_transport_step));
}

// Keep the original six-argument ABI for older hosts and external integrations.
extern "C" char * LuminaMiniCPMV46ExternalGenerateReActJSON(
    const char * model_directory,
    const char * backend_preference,
    const char * prompt,
    int context_length,
    int max_output_tokens,
    int safety_margin_tokens
) {
    return LuminaMiniCPMV46ExternalGenerateReActJSONCancellable(
        model_directory, backend_preference, prompt, context_length,
        max_output_tokens, safety_margin_tokens, nullptr, nullptr
    );
}

extern "C" void LuminaMiniCPMV46ExternalFreeCString(char * value) {
    std::free(value);
}

// Wait for an active request, release the model before the backend, and retain
// the loaded library. This is idempotent; a subsequent request can load again.
extern "C" void LuminaMiniCPMV46ExternalShutdown(void) {
    cleanup_backend();
}
