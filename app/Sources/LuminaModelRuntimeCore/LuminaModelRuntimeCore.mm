#include "include/LuminaModelRuntimeCore.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <sstream>
#include <string>
#include <utility>
#include <vector>
#include <dlfcn.h>
#include <unistd.h>

#if __has_include(<Metal/Metal.h>)
#import <Metal/Metal.h>
#define LUMINA_HAS_METAL 1
#else
#define LUMINA_HAS_METAL 0
#endif

namespace {

enum class LuminaMiniCPMV46Backend {
    automatic,
    ane,
    mps
};

struct LuminaMiniCPMV46KVCachePlan {
    int contextLength = 16000;
    int layers = 24;
    int keyValueHeads = 2;
    int keyLength = 256;
    int valueLength = 256;
    int bytesPerElement = 2;

    long long bytesPerToken() const {
        return static_cast<long long>(layers) * (keyLength + valueLength) * bytesPerElement;
    }

    long long totalBytes() const {
        return bytesPerToken() * contextLength;
    }
};

struct LuminaMiniCPMV46OperatorPlan {
    bool fusedRMSNorm = true;
    bool fusedRotaryEmbedding = true;
    bool fusedQKVGemm = true;
    bool pagedKVCache = true;
    int decodeTileTokens = 1;
    int prefillTileTokens = 256;
};

struct LuminaMiniCPMV46EnginePlan {
    LuminaMiniCPMV46Backend backend = LuminaMiniCPMV46Backend::automatic;
    LuminaMiniCPMV46KVCachePlan kvCache;
    LuminaMiniCPMV46OperatorPlan operators;
};

struct LuminaMiniCPMV46BackendProbe {
    bool mpsReady = false;
    bool aneReady = false;
    std::string mpsDeviceName;
    std::string mpsFailureReason;
    std::string aneFailureReason;
};

using LuminaExternalGenerateFunction = char * (*)(
    const char *,
    const char *,
    const char *,
    int,
    int,
    int
);

struct LuminaExternalEngine {
    void * handle = nullptr;
    LuminaExternalGenerateFunction generate = nullptr;
    std::string path;
    std::string error;
};

LuminaMiniCPMV46BackendProbe probeBackends() {
    LuminaMiniCPMV46BackendProbe probe;
#if LUMINA_HAS_METAL
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (device != nil) {
            probe.mpsReady = true;
            probe.mpsDeviceName = [[device name] UTF8String] ?: "";
        } else {
            probe.mpsFailureReason = "Metal device is unavailable on this host.";
        }
    }
#else
    probe.mpsFailureReason = "Metal framework is unavailable in this build.";
#endif
    probe.aneFailureReason = "ANE execution requires a compiled MiniCPM-V Core ML partition; no ANE partition is linked in this build.";
    return probe;
}

std::string escapeJSON(const std::string &value) {
    std::string escaped;
    escaped.reserve(value.size() + 16);
    for (char c : value) {
        switch (c) {
        case '"': escaped += "\\\""; break;
        case '\\': escaped += "\\\\"; break;
        case '\b': escaped += "\\b"; break;
        case '\f': escaped += "\\f"; break;
        case '\n': escaped += "\\n"; break;
        case '\r': escaped += "\\r"; break;
        case '\t': escaped += "\\t"; break;
        default:
            if (static_cast<unsigned char>(c) < 0x20) {
                escaped += "\\u00";
                const char *hex = "0123456789abcdef";
                escaped += hex[(c >> 4) & 0x0F];
                escaped += hex[c & 0x0F];
            } else {
                escaped += c;
            }
        }
    }
    return escaped;
}

char *copyCString(const std::string &value) {
    auto *buffer = static_cast<char *>(std::malloc(value.size() + 1));
    if (buffer == nullptr) {
        return nullptr;
    }
    std::memcpy(buffer, value.c_str(), value.size() + 1);
    return buffer;
}

bool fileExists(const std::string &path) {
    return !path.empty() && access(path.c_str(), R_OK) == 0;
}

std::vector<std::string> externalEngineCandidates(const char *modelDirectory) {
    std::vector<std::string> candidates;
    if (const char *override = std::getenv("LUMINA_MINICPMV46_ENGINE")) {
        candidates.emplace_back(override);
    }
    if (modelDirectory != nullptr && std::strlen(modelDirectory) > 0) {
        std::string root(modelDirectory);
        candidates.push_back(root + "/libLuminaMiniCPMV46GGUFEngine.dylib");
        candidates.push_back(root + "/NativeEngine/libLuminaMiniCPMV46GGUFEngine.dylib");
    }
    return candidates;
}

LuminaExternalEngine loadExternalEngine(const char *modelDirectory) {
    LuminaExternalEngine engine;
    for (const auto &candidate : externalEngineCandidates(modelDirectory)) {
        if (!fileExists(candidate)) {
            continue;
        }
        void *handle = dlopen(candidate.c_str(), RTLD_NOW | RTLD_LOCAL);
        if (handle == nullptr) {
            engine.error = dlerror() ?: "dlopen failed";
            continue;
        }
        auto generate = reinterpret_cast<LuminaExternalGenerateFunction>(
            dlsym(handle, "LuminaMiniCPMV46ExternalGenerateReActJSON")
        );
        if (generate == nullptr) {
            engine.error = "LuminaMiniCPMV46ExternalGenerateReActJSON symbol not found in " + candidate;
            dlclose(handle);
            continue;
        }
        engine.handle = handle;
        engine.generate = generate;
        engine.path = candidate;
        engine.error.clear();
        return engine;
    }
    if (engine.error.empty()) {
        engine.error = "No MiniCPM-V GGUF decoder dylib found. Set LUMINA_MINICPMV46_ENGINE or place libLuminaMiniCPMV46GGUFEngine.dylib beside model.gguf.";
    }
    return engine;
}

int approximateTokenCount(const char *prompt) {
    if (prompt == nullptr) {
        return 0;
    }
    return std::max(1, static_cast<int>(std::ceil(std::strlen(prompt) / 3.6)));
}

LuminaMiniCPMV46Backend parseBackend(const char *backendPreference) {
    std::string value = backendPreference == nullptr ? "automatic" : backendPreference;
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) {
        return static_cast<char>(std::tolower(c));
    });
    if (value == "ane") {
        return LuminaMiniCPMV46Backend::ane;
    }
    if (value == "mps" || value == "metal") {
        return LuminaMiniCPMV46Backend::mps;
    }
    return LuminaMiniCPMV46Backend::automatic;
}

std::string backendName(LuminaMiniCPMV46Backend backend) {
    switch (backend) {
    case LuminaMiniCPMV46Backend::ane:
        return "ane";
    case LuminaMiniCPMV46Backend::mps:
        return "mps";
    case LuminaMiniCPMV46Backend::automatic:
        return "automatic";
    }
}

std::string unavailableResponse(
    const LuminaMiniCPMV46EnginePlan &plan,
    const char *modelDirectory,
    const char *prompt,
    int maxOutputTokens,
    int safetyMarginTokens,
    const std::string &engineError
) {
    const int promptTokens = approximateTokenCount(prompt);
    std::ostringstream json;
    json << "{";
    json << "\"ok\":false,";
    json << "\"backend\":\"" << backendName(plan.backend) << "\",";
    json << "\"modelDirectory\":\"" << escapeJSON(modelDirectory == nullptr ? "" : modelDirectory) << "\",";
    json << "\"promptTokens\":" << promptTokens << ",";
    json << "\"outputTokens\":0,";
    json << "\"maxOutputTokens\":" << maxOutputTokens << ",";
    json << "\"contextLength\":" << plan.kvCache.contextLength << ",";
    json << "\"safetyMarginTokens\":" << safetyMarginTokens << ",";
    json << "\"kvCacheBytes\":" << plan.kvCache.totalBytes() << ",";
    json << "\"mpsDeviceName\":\"" << escapeJSON(probeBackends().mpsDeviceName) << "\",";
    json << "\"timeToFirstTokenMilliseconds\":null,";
    json << "\"generationMilliseconds\":0,";
    json << "\"totalMilliseconds\":0,";
    json << "\"tokensPerSecond\":0,";
    json << "\"error\":\"MiniCPM-V 4.6 native GGUF decoder is unavailable. "
         << escapeJSON(engineError)
         << "\"";
    json << "}";
    return json.str();
}

std::string capabilitiesJSON() {
    LuminaMiniCPMV46EnginePlan plan;
    LuminaMiniCPMV46BackendProbe probe = probeBackends();
    std::ostringstream json;
    json << "{";
    json << "\"engine\":\"LuminaModelRuntimeCore\",";
    json << "\"model\":\"MiniCPM-V 4.6\",";
    json << "\"contextLength\":" << plan.kvCache.contextLength << ",";
    json << "\"kvCacheBytes\":" << plan.kvCache.totalBytes() << ",";
    json << "\"aneReady\":" << (probe.aneReady ? "true" : "false") << ",";
    json << "\"mpsReady\":" << (probe.mpsReady ? "true" : "false") << ",";
    json << "\"mpsDeviceName\":\"" << escapeJSON(probe.mpsDeviceName) << "\",";
    json << "\"aneFailureReason\":\"" << escapeJSON(probe.aneFailureReason) << "\",";
    json << "\"mpsFailureReason\":\"" << escapeJSON(probe.mpsFailureReason) << "\",";
    json << "\"optimizations\":[";
    json << "\"miniCPM-v-specific-kv-cache-shape\",";
    json << "\"paged-kv-cache-plan\",";
    json << "\"fused-rmsnorm-plan\",";
    json << "\"fused-rotary-embedding-plan\",";
    json << "\"fused-qkv-gemm-plan\",";
    json << "\"dynamic-output-budget\"";
    json << "]";
    json << "}";
    return json.str();
}

} // namespace

extern "C" char *LuminaMiniCPMV46BackendCapabilities(void) {
    return copyCString(capabilitiesJSON());
}

extern "C" char *LuminaMiniCPMV46GenerateReActJSON(
    const char *modelDirectory,
    const char *backendPreference,
    const char *prompt,
    int contextLength,
    int maxOutputTokens,
    int safetyMarginTokens
) {
    LuminaMiniCPMV46EnginePlan plan;
    plan.backend = parseBackend(backendPreference);
    plan.kvCache.contextLength = contextLength > 0 ? contextLength : 16000;
    LuminaExternalEngine external = loadExternalEngine(modelDirectory);
    if (external.generate != nullptr) {
        char *response = external.generate(
            modelDirectory,
            backendPreference,
            prompt,
            plan.kvCache.contextLength,
            maxOutputTokens,
            safetyMarginTokens
        );
        return response;
    }
    return copyCString(unavailableResponse(
        plan,
        modelDirectory,
        prompt,
        maxOutputTokens,
        safetyMarginTokens,
        external.error
    ));
}

extern "C" void LuminaModelRuntimeFreeCString(char *value) {
    std::free(value);
}
