#pragma once

#include <string>

#include "Callbacks.hpp"

namespace LuminaAgent {

class HookDispatcher {
public:
    explicit HookDispatcher(const RuntimeCallbacks &callbacks);

    std::string dispatch(const std::string &lifecycle, const std::string &payload = "{}") const;

private:
    const RuntimeCallbacks &callbacks_;
};

} // namespace LuminaAgent
