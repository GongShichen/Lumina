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
bool g_backend_initialized = false;

void cleanup_backend() {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_model != nullptr) {
        llama_model_free(g_model);
        g_model = nullptr;
        g_loaded_model_path.clear();
    }
    if (g_backend_initialized) {
        llama_backend_free();
        g_backend_initialized = false;
    }
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
    if (std::filesystem::exists(model)) {
        return model.string();
    }
    for (const auto & entry : std::filesystem::directory_iterator(root)) {
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

bool ensure_model_loaded(const std::string & model_path, std::string & error) {
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
    model_params.n_gpu_layers = 999;
    model_params.use_mmap = true;
    model_params.use_mlock = false;
    model_params.check_tensors = false;

    g_model = llama_model_load_from_file(model_path.c_str(), model_params);
    if (g_model == nullptr) {
        error = "Failed to load MiniCPM-V GGUF model at " + model_path;
        return false;
    }
    g_loaded_model_path = model_path;
    return true;
}

bool prompt_requests_xml_react(const std::string & prompt) {
    return prompt.find("Lumina XML ReAct step") != std::string::npos ||
           prompt.find("XML ReAct step") != std::string::npos ||
           prompt.find("XML-tag ReAct step") != std::string::npos ||
           prompt.find("FIRST BYTES MUST BE <thought>") != std::string::npos ||
           prompt.find("CRITICAL OUTPUT CONTRACT") != std::string::npos ||
           prompt.find("xml_tags") != std::string::npos ||
           prompt.find("<tool_use") != std::string::npos ||
           prompt.find("<result>") != std::string::npos ||
           prompt.find("<ask_user>") != std::string::npos ||
           prompt.find("<cannot_complete>") != std::string::npos;
}

std::string chat_wrapped_prompt(const std::string & prompt) {
    if (prompt.find("<|im_start|>") != std::string::npos) {
        return prompt;
    }
    if (prompt_requests_xml_react(prompt)) {
        return "<|im_start|>system\n"
               "You are Lumina, an on-device XML ReAct agent. FIRST BYTES MUST BE <thought>. "
               "Output exactly one valid Lumina XML ReAct step and no prose, markdown, JSON object, or <think> block.\n"
               "<|im_end|>\n"
               "<|im_start|>user\n" + prompt + "\n<|im_end|>\n"
               "<|im_start|>assistant\n";
    }
    return "<|im_start|>system\n"
           "You are Lumina, an on-device ReAct agent. Output exactly one compact JSON object and no prose.\n"
           "<|im_end|>\n"
           "<|im_start|>user\n" + prompt + "\n<|im_end|>\n"
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
        return "";
    }
    return std::string(buffer, static_cast<size_t>(n));
}

bool probably_complete_json(const std::string & text) {
    int depth = 0;
    bool in_string = false;
    bool escaped = false;
    bool saw_open = false;
    for (char c : text) {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (c == '\\' && in_string) {
            escaped = true;
            continue;
        }
        if (c == '"') {
            in_string = !in_string;
            continue;
        }
        if (in_string) {
            continue;
        }
        if (c == '{') {
            saw_open = true;
            depth += 1;
        } else if (c == '}') {
            depth -= 1;
            if (saw_open && depth == 0) {
                return true;
            }
        }
    }
    return false;
}

bool likely_json_started(const std::string & text) {
    return text.find('{') != std::string::npos;
}

bool is_schema_step_generation(const std::string & prompt) {
    return prompt.find("ReAct step schema") != std::string::npos ||
           prompt.find("\"type\":\"tool_use\"") != std::string::npos ||
           prompt.find("\"type\":\"result\"") != std::string::npos;
}

bool is_xml_step_generation(const std::string & prompt) {
    return prompt_requests_xml_react(prompt);
}

bool starts_with_json_object(const std::string & text) {
    const auto first = std::find_if_not(text.begin(), text.end(), [](unsigned char c) {
        return std::isspace(c);
    });
    return first != text.end() && *first == '{';
}

bool starts_with_prefix(const std::string & text, const std::string & prefix) {
    return text.size() >= prefix.size() && text.compare(0, prefix.size(), prefix) == 0;
}

std::string trim_left_copy(const std::string & text) {
    const auto first = std::find_if_not(text.begin(), text.end(), [](unsigned char c) {
        return std::isspace(c);
    });
    return first == text.end() ? "" : std::string(first, text.end());
}

std::string xml_step_search_region(const std::string & text) {
    const std::string trimmed = trim_left_copy(text);
    if (starts_with_prefix(trimmed, "<think") ||
        trimmed.find("<tool_call") != std::string::npos ||
        trimmed.find("<observation") != std::string::npos) {
        return "";
    }
    return trimmed;
}

bool contains_complete_xml_step(const std::string & text) {
    const std::string region = xml_step_search_region(text);
    if (region.empty()) {
        return false;
    }
    const std::pair<const char *, const char *> step_tags[] = {
        {"<tool_use", "</tool_use>"},
        {"<result>", "</result>"},
        {"<ask_user>", "</ask_user>"},
        {"<cannot_complete>", "</cannot_complete>"}
    };
    for (const auto & tag : step_tags) {
        const size_t open = region.find(tag.first);
        if (open == std::string::npos) {
            continue;
        }
        const size_t close = region.find(tag.second, open);
        if (close != std::string::npos) {
            return true;
        }
    }
    return false;
}

std::string expected_unclosed_xml_step_close(const std::string & text) {
    const std::string region = xml_step_search_region(text);
    if (region.empty()) {
        return "";
    }
    const std::pair<const char *, const char *> step_tags[] = {
        {"<tool_use", "</tool_use>"},
        {"<result>", "</result>"},
        {"<ask_user>", "</ask_user>"},
        {"<cannot_complete>", "</cannot_complete>"}
    };
    size_t best_open = std::string::npos;
    const char * best_close = nullptr;
    for (const auto & tag : step_tags) {
        const size_t open = region.rfind(tag.first);
        if (open == std::string::npos) {
            continue;
        }
        if (region.find(tag.second, open) != std::string::npos) {
            continue;
        }
        if (best_open == std::string::npos || open > best_open) {
            best_open = open;
            best_close = tag.second;
        }
    }
    return best_close == nullptr ? "" : std::string(best_close);
}

bool append_xml_eog_closing_repair(std::string & text) {
    const std::string close = expected_unclosed_xml_step_close(text);
    if (close.empty()) {
        return false;
    }
    for (size_t prefix = close.size(); prefix > 0; --prefix) {
        if (text.size() >= prefix && text.compare(text.size() - prefix, prefix, close, 0, prefix) == 0) {
            text += close.substr(prefix);
            return true;
        }
    }
    return false;
}

std::string lowercase_ascii(std::string text) {
    std::transform(text.begin(), text.end(), text.begin(), [](unsigned char c) {
        return static_cast<char>(std::tolower(c));
    });
    return text;
}

bool ends_with_forbidden_xml_prefix(const std::string & lowered) {
    static const std::vector<std::string> forbidden = {
        "<think", "</think", "<tool_call", "</tool_call", "<observation", "</observation"
    };
    for (const std::string & tag : forbidden) {
        for (size_t length = 4; length < tag.size(); ++length) {
            if (lowered.size() >= length &&
                lowered.compare(lowered.size() - length, length, tag, 0, length) == 0) {
                return true;
            }
        }
    }
    return false;
}

bool violates_forbidden_xml_contract(const std::string & candidate) {
    const std::string lowered = lowercase_ascii(candidate);
    static const std::vector<std::string> forbidden = {
        "<think", "</think>", "<tool_call", "</tool_call>", "<observation", "</observation>"
    };
    for (const std::string & tag : forbidden) {
        if (lowered.find(tag) != std::string::npos) {
            return true;
        }
    }
    return ends_with_forbidden_xml_prefix(lowered);
}

} // namespace

extern "C" char * LuminaMiniCPMV46ExternalGenerateReActJSON(
    const char * model_directory,
    const char * backend_preference,
    const char * prompt,
    int context_length,
    int max_output_tokens,
    int safety_margin_tokens
) {
    (void) safety_margin_tokens;
    printf("[Lumina][C++] Starting generation request...\n"); fflush(stdout);
    auto start = std::chrono::steady_clock::now();
    std::lock_guard<std::mutex> lock(g_mutex);

    const std::string backend = backend_preference == nullptr ? "automatic" : backend_preference;
    const std::string raw_prompt = prompt == nullptr ? "" : prompt;
    const std::string model_path = model_path_for_directory(model_directory);
    printf("[Lumina][C++] Model path: %s\n", model_path.c_str());
    if (model_path.empty()) {
        return copy_c_string(make_response(false, backend, 0, 0, max_output_tokens, context_length, -1, 0, 0, "", "MiniCPM-V model.gguf was not found.", false));
    }

    std::string error;
    if (!ensure_model_loaded(model_path, error)) {
        printf("[Lumina][C++] Model load FAILED: %s\n", error.c_str());
        return copy_c_string(make_response(false, backend, 0, 0, max_output_tokens, context_length, -1, 0, 0, "", error, false));
    }
    printf("[Lumina][C++] Model loaded successfully.\n"); fflush(stdout);

    const llama_vocab * vocab = llama_model_get_vocab(g_model);
    const std::string prompt_text = chat_wrapped_prompt(raw_prompt);
    printf("[Lumina][C++] Tokenizing prompt (length: %zu)...\n", prompt_text.size());
    const bool prompt_has_chat_template = prompt_text.find("<|im_start|>") != std::string::npos;
    std::vector<llama_token> prompt_tokens = tokenize(vocab, prompt_text, !prompt_has_chat_template, error);
    if (prompt_tokens.empty()) {
        printf("[Lumina][C++] Tokenization FAILED.\n");
        return copy_c_string(make_response(false, backend, 0, 0, max_output_tokens, context_length, -1, 0, 0, "", error, false));
    }
    printf("[Lumina][C++] Tokens count: %zu\n", prompt_tokens.size());

    const bool xml_step = is_xml_step_generation(raw_prompt);
    const bool schema_step = xml_step || is_schema_step_generation(raw_prompt);
    const int requested_max_output_tokens = max_output_tokens;
    if (static_cast<int>(prompt_tokens.size()) >= context_length) {
        return copy_c_string(make_response(
            false,
            backend,
            static_cast<int>(prompt_tokens.size()),
            0,
            max_output_tokens,
            context_length,
            -1,
            0,
            0,
            "",
            "MiniCPM-V prompt tokens exceed the configured context window; compact context before decoding.",
            schema_step
        ));
    }
    const int effective_max_output_tokens = schema_step
        ? std::min(std::max(max_output_tokens, 128), 768)
        : std::min(max_output_tokens, std::max(256, context_length - static_cast<int>(prompt_tokens.size()) - safety_margin_tokens));
    const int active_context_length = std::min(
        context_length,
        std::max(
            512,
            static_cast<int>(prompt_tokens.size()) + effective_max_output_tokens + std::max(64, safety_margin_tokens)
        )
    );

    llama_context_params ctx_params = llama_context_default_params();
    ctx_params.n_ctx = static_cast<uint32_t>(active_context_length);
    ctx_params.n_batch = static_cast<uint32_t>(std::min<int>(
        std::max<int>(static_cast<int>(prompt_tokens.size()), 512),
        active_context_length
    ));
    ctx_params.n_ubatch = ctx_params.n_batch;
    ctx_params.n_threads = std::max(2u, std::thread::hardware_concurrency() / 2);
    ctx_params.n_threads_batch = std::max(2u, std::thread::hardware_concurrency());
    ctx_params.no_perf = false;
    ctx_params.offload_kqv = true;
    ctx_params.op_offload = true;
    ctx_params.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO;

    llama_context * ctx = llama_init_from_model(g_model, ctx_params);
    if (ctx == nullptr) {
        printf("[Lumina][C++] Failed to create llama context.\n");
        return copy_c_string(make_response(false, backend, static_cast<int>(prompt_tokens.size()), 0, max_output_tokens, context_length, -1, 0, 0, "", "Failed to create MiniCPM-V llama context.", schema_step));
    }
    printf("[Lumina][C++] Llama context created with n_ctx: %u\n", ctx_params.n_ctx);

    llama_sampler_chain_params sampler_params = llama_sampler_chain_default_params();
    sampler_params.no_perf = false;
    llama_sampler * sampler = llama_sampler_chain_init(sampler_params);
    llama_sampler_chain_add(sampler, llama_sampler_init_greedy());

    printf("[Lumina][C++] Decoding prompt batch (size: %zu)...\n", prompt_tokens.size()); fflush(stdout);
    llama_batch batch = llama_batch_get_one(prompt_tokens.data(), static_cast<int32_t>(prompt_tokens.size()));
    int32_t decode_result = llama_decode(ctx, batch);
    if (decode_result != 0) {
        printf("[Lumina][C++] Prompt decode FAILED with code: %d\n", decode_result);
        llama_sampler_free(sampler);
        llama_free(ctx);
        return copy_c_string(make_response(false, backend, static_cast<int>(prompt_tokens.size()), 0, max_output_tokens, context_length, -1, 0, 0, "", "MiniCPM-V prompt decode failed with code " + std::to_string(decode_result) + ".", schema_step));
    }
    printf("[Lumina][C++] Prompt decoded. Starting generation loop...\n");

    std::string output;
    int output_tokens = 0;
    double ttft_ms = -1;
    auto generation_start = std::chrono::steady_clock::now();

    int tokens_after_first_json_char = 0;
    for (int i = 0; i < effective_max_output_tokens; ++i) {
        llama_token token = llama_sampler_sample(sampler, ctx, -1);
        if (llama_vocab_is_eog(vocab, token)) {
            if (xml_step && append_xml_eog_closing_repair(output) && contains_complete_xml_step(output)) {
                break;
            }
            break;
        }
        llama_sampler_accept(sampler, token);
        if (output_tokens == 0) {
            auto now = std::chrono::steady_clock::now();
            ttft_ms = std::chrono::duration<double, std::milli>(now - start).count();
        }
        output += token_piece(vocab, token);
        output_tokens += 1;
        if (likely_json_started(output)) {
            tokens_after_first_json_char += 1;
        }
        if (xml_step) {
            if (contains_complete_xml_step(output)) {
                break;
            }
            if (starts_with_json_object(output) && probably_complete_json(output)) {
                break;
            }
        } else {
            if (probably_complete_json(output)) {
                break;
            }
            if (schema_step && !likely_json_started(output) && output_tokens >= 96) {
                break;
            }
            if (schema_step && likely_json_started(output) && tokens_after_first_json_char >= 512) {
                break;
            }
        }
        batch = llama_batch_get_one(&token, 1);
        decode_result = llama_decode(ctx, batch);
        if (decode_result != 0) {
            break;
        }
    }

    auto end = std::chrono::steady_clock::now();
    double generation_ms = std::chrono::duration<double, std::milli>(end - generation_start).count();
    double total_ms = std::chrono::duration<double, std::milli>(end - start).count();

    llama_sampler_free(sampler);
    llama_free(ctx);

    return copy_c_string(make_response(true, backend, static_cast<int>(prompt_tokens.size()), output_tokens, requested_max_output_tokens, context_length, ttft_ms, generation_ms, total_ms, output, "", schema_step));
}

extern "C" void LuminaMiniCPMV46ExternalFreeCString(char * value) {
    std::free(value);
}
