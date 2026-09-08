#pragma once

#include <string>

#include "Callbacks.hpp"

namespace LuminaAgent {

struct RuntimeHookDirectives {
    bool hasFail = false;
    bool hasPause = false;
    bool hasRejectToolCall = false;
    bool rejectionValidationFailed = false;
    std::string rejectionOutputJson;
    bool hasRewriteToolCall = false;
    bool requiresConfirmation = false;
    bool hasAppendContext = false;
    std::string reason;
    std::string markdown;
    std::string pauseKind;
    std::string pausePayloadJson;
    std::string appendedContextJson;
    std::string rewrittenToolName;
    std::string rewrittenParametersJson;
};

class HookDispatcher {
public:
    // Binds dispatch to the caller-installed hook callback set.
    explicit HookDispatcher(const RuntimeCallbacks &callbacks);

    // Sends a lifecycle payload and returns a generic hook directive JSON object.
    std::string dispatch(const std::string &lifecycle, const std::string &payload = "{}") const;

private:
    const RuntimeCallbacks &callbacks_;
};

// Parses hook directive JSON returned by the caller. Supports either one
// directive object or a `{"directives":[...]}` envelope.
RuntimeHookDirectives parseRuntimeHookDirectives(const std::string &directiveJson);

} // namespace LuminaAgent
