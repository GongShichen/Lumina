#include "LuminaAgentRuntime.h"

#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>

namespace {

char *copyCString(const std::string &value) {
    auto *buffer = static_cast<char *>(std::malloc(value.size() + 1));
    if (buffer == nullptr) {
        return nullptr;
    }
    std::memcpy(buffer, value.c_str(), value.size() + 1);
    return buffer;
}

char *fakeModelCallback(const char *, void *) {
    return copyCString(R"({"type":"final_answer","content":"### Linux conformance\n\nRuntime callback path is alive."})");
}

char *fakeToolCallback(const char *, void *) {
    return copyCString(R"({"status":"succeeded","content":"fake tool executed"})");
}

void fakeEventCallback(const char *eventJson, void *) {
    if (eventJson != nullptr) {
        std::cout << eventJson << '\n';
    }
}

} // namespace

int main() {
    LuminaAgentRuntimeRef *runtime = LuminaAgentRuntimeCreate(R"({"maximumReActIterations":1})");
    if (runtime == nullptr) {
        std::cerr << "failed to create LuminaAgentRuntime\n";
        return 1;
    }

    LuminaAgentRuntimeSetModelCallback(runtime, fakeModelCallback, nullptr);
    LuminaAgentRuntimeSetToolCallback(runtime, fakeToolCallback, nullptr);
    LuminaAgentRuntimeSetEventCallback(runtime, fakeEventCallback, nullptr);

    char *toolStatus = LuminaAgentRuntimeRegisterToolSchema(
        runtime,
        R"({"name":"conformance.echo","description":"Fake conformance echo tool","parameters":{"type":"object"},"sideEffect":"none"})"
    );
    LuminaAgentRuntimeReleaseString(toolStatus);

    char *result = LuminaAgentRuntimeRun(runtime, R"({"id":"linux-conformance","text":"Say hello from Linux."})");
    if (result == nullptr) {
        LuminaAgentRuntimeDestroy(runtime);
        std::cerr << "runtime returned null result\n";
        return 1;
    }

    std::cout << result << '\n';
    LuminaAgentRuntimeReleaseString(result);
    LuminaAgentRuntimeDestroy(runtime);
    return 0;
}

