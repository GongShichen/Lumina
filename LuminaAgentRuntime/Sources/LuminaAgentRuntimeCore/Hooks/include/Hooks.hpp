#pragma once

#include <string>

#include "Callbacks.hpp"

namespace LuminaAgent {

class HookDispatcher {
public:
    // Binds dispatch to the caller-installed hook callback set.
    explicit HookDispatcher(const RuntimeCallbacks &callbacks);

    // Sends a lifecycle payload and returns a generic hook directive JSON object.
    std::string dispatch(const std::string &lifecycle, const std::string &payload = "{}") const;

private:
    const RuntimeCallbacks &callbacks_;
};

} // namespace LuminaAgent
