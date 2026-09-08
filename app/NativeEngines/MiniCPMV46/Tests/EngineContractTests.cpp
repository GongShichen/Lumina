// Compile against the pinned llama headers without loading a model or GPU:
// clang++ -std=c++17 -I.build/vendor/llama.cpp/include -I.build/vendor/llama.cpp/ggml/include \
//   app/NativeEngines/MiniCPMV46/Tests/EngineContractTests.cpp -o /tmp/lumina-engine-contract-tests
// /tmp/lumina-engine-contract-tests
#include "../LuminaMiniCPMV46GGUFEngine.cpp"
#include <cassert>
#include <fstream>

struct llama_model {};
struct llama_vocab {};
struct llama_context {};

namespace fake {
int prompt_tokens = 10;
int decode_calls = 0;
int sample_calls = 0;
int fail_decode_call = 0;
int cancel_decode_call = 0;
int largest_batch = 0;
int live_models = 0;
int live_contexts = 0;
int model_frees = 0;
int backend_inits = 0;
int backend_frees = 0;
bool cancelled = false;
bool gpu = true;
std::string piece = "<tool_call><function=final_answer><parameter=text>done</parameter></function></tool_call>";
llama_context_params context_params{};

void reset() {
    prompt_tokens = 10;
    decode_calls = sample_calls = fail_decode_call = cancel_decode_call = largest_batch = 0;
    cancelled = false;
    piece = "<tool_call><function=final_answer><parameter=text>done</parameter></function></tool_call>";
}
bool is_cancelled(void *) { return cancelled; }

struct BackendRegistry {
    ~BackendRegistry() {
        assert(live_models == 0 && live_contexts == 0);
        assert(backend_inits == backend_frees);
        puts("PASS: normal-exit cleanup precedes backend registry destruction");
    }
};
struct BufferTypes {
    ~BufferTypes() { assert(live_models == 0); }
};
}

extern "C" {
void llama_backend_init() { ++fake::backend_inits; }
void llama_backend_free() {
    assert(fake::live_models == 0 && fake::live_contexts == 0);
    ++fake::backend_frees;
}
void ggml_backend_load_all() { static fake::BackendRegistry registry; }
void llama_log_set(ggml_log_callback, void *) {}
llama_model_params llama_model_default_params() { return {}; }
llama_context_params llama_context_default_params() { return {}; }
llama_sampler_chain_params llama_sampler_chain_default_params() { return {}; }
ggml_backend_dev_t ggml_backend_dev_by_type(enum ggml_backend_dev_type) {
    return fake::gpu ? reinterpret_cast<ggml_backend_dev_t>(1) : nullptr;
}
llama_model *llama_model_load_from_file(const char *, llama_model_params) {
    static fake::BufferTypes buffers;
    ++fake::live_models;
    return new llama_model;
}
void llama_model_free(llama_model *model) {
    assert(fake::live_contexts == 0);
    --fake::live_models;
    ++fake::model_frees;
    delete model;
}
const llama_vocab *llama_model_get_vocab(const llama_model *) { static llama_vocab vocab; return &vocab; }
int32_t llama_tokenize(const llama_vocab *, const char *, int32_t, llama_token *tokens, int32_t capacity, bool, bool) {
    if (capacity < fake::prompt_tokens) { return -fake::prompt_tokens; }
    std::fill(tokens, tokens + fake::prompt_tokens, 1);
    return fake::prompt_tokens;
}
int32_t llama_token_to_piece(const llama_vocab *, llama_token, char *buffer, int32_t capacity, int32_t, bool) {
    if (capacity < static_cast<int32_t>(fake::piece.size())) { return -static_cast<int32_t>(fake::piece.size()); }
    std::memcpy(buffer, fake::piece.data(), fake::piece.size());
    return static_cast<int32_t>(fake::piece.size());
}
llama_context *llama_init_from_model(llama_model *, llama_context_params params) {
    fake::context_params = params;
    ++fake::live_contexts;
    return new llama_context;
}
void llama_free(llama_context *context) { --fake::live_contexts; delete context; }
llama_sampler *llama_sampler_chain_init(llama_sampler_chain_params) { return new llama_sampler{}; }
llama_sampler *llama_sampler_init_greedy() { return new llama_sampler{}; }
void llama_sampler_chain_add(llama_sampler *, llama_sampler *child) { delete child; }
void llama_sampler_free(llama_sampler *sampler) { delete sampler; }
void llama_sampler_accept(llama_sampler *, llama_token) {}
llama_token llama_sampler_sample(llama_sampler *, llama_context *, int32_t) { ++fake::sample_calls; return 1; }
bool llama_vocab_is_eog(const llama_vocab *, llama_token) { return false; }
llama_batch llama_batch_get_one(llama_token *tokens, int32_t count) {
    llama_batch batch{};
    batch.n_tokens = count;
    batch.token = tokens;
    return batch;
}
int32_t llama_decode(llama_context *, llama_batch batch) {
    ++fake::decode_calls;
    fake::largest_batch = std::max(fake::largest_batch, batch.n_tokens);
    if (fake::decode_calls == fake::cancel_decode_call) { fake::cancelled = true; }
    return fake::decode_calls == fake::fail_decode_call ? -7 : 0;
}
}

int main() {
    const auto directory = std::filesystem::temp_directory_path() /
        ("lumina-native-contract-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    std::filesystem::create_directories(directory);
    std::ofstream(directory / "model.gguf").put('x');
    const auto run = [&](int context = 16000, int maximum = 192, int margin = 256,
                         const char *preference = "automatic", const char *prompt = "minicpm_v46_tool_calls") {
        char *raw = LuminaMiniCPMV46ExternalGenerateReActJSONCancellable(
            directory.c_str(), preference, prompt, context, maximum, margin, fake::is_cancelled, nullptr);
        assert(raw != nullptr);
        std::string response(raw);
        std::free(raw);
        return response;
    };
    const auto contains = [](const std::string &response, const std::string &expected) {
        if (response.find(expected) == std::string::npos) {
            fprintf(stderr, "Expected %s in %s\n", expected.c_str(), response.c_str());
            std::abort();
        }
    };

    fake::reset();
    fake::prompt_tokens = 15990;
    contains(run(), "\"ok\":false");
    assert(fake::decode_calls == 0);
    contains(run(16000, 192, 256, "automatic", "plain prompt"), "context window exhausted");
    assert(fake::decode_calls == 0);

    fake::reset();
    contains(run(100, 192, 89), "\"maxOutputTokens\":1");
    assert(fake::sample_calls == 1);
    assert(fake::context_params.n_ctx <= 100);
    fake::reset();
    contains(run(16000, 1), "\"maxOutputTokens\":1");
    assert(fake::sample_calls == 1); // Caller cap must not be raised to 128.

    fake::reset();
    fake::piece = "incomplete";
    contains(run(16000, 2), "output token budget exhausted");
    assert(fake::sample_calls == 2);
    fake::reset();
    fake::fail_decode_call = 1;
    contains(run(), "prompt decode failed with code -7");
    fake::reset();
    fake::piece = "incomplete";
    fake::fail_decode_call = 2;
    auto response = run();
    contains(response, "\"ok\":false");
    contains(response, "token decode failed with code -7");
    assert(response.find("\"output\":") == std::string::npos);

    fake::reset();
    fake::prompt_tokens = 1024;
    fake::cancel_decode_call = 1;
    contains(run(), "cancelled during prompt decoding");
    assert(fake::decode_calls == 1 && fake::largest_batch == 256 && fake::sample_calls == 0);
    fake::reset();
    fake::piece = "incomplete";
    fake::cancel_decode_call = 2;
    contains(run(), "cancelled");
    assert(fake::sample_calls == 1);
    fake::reset(); // A cancelled request cannot poison the next request.
    contains(run(), "\"ok\":true");

    fake::reset();
    contains(run(16000, 192, 256, "ane"), "ANE is unavailable");
    assert(fake::decode_calls == 0);
    contains(run(), "\"backend\":\"mps\"");
    LuminaMiniCPMV46ExternalShutdown();
    const int frees_after_shutdown = fake::model_frees;
    const int backend_frees_after_shutdown = fake::backend_frees;
    LuminaMiniCPMV46ExternalShutdown();
    assert(fake::model_frees == frees_after_shutdown);
    assert(fake::backend_frees == backend_frees_after_shutdown);
    fake::gpu = false;
    contains(run(), "\"backend\":\"cpu\"");
    contains(run(16000, 192, 256, "metal"), "Metal was requested");

    fake::reset();
    fake::piece = "<tool_call>" + std::string(600, 'x') + "</tool_call>";
    contains(run(), "\"ok\":true"); // Large tokenizer pieces are not silently dropped.
    // Intentionally leave the final cached model loaded. Normal process exit
    // must release it before the simulated buffer/device registry destructors.
    assert(fake::live_models == 1 && fake::live_contexts == 0);
    std::filesystem::remove_all(directory);
    puts("PASS: native context budget, caller cap, incomplete/decode failures, cancellation, next request, backend reporting, large token pieces");
}
