#include "Hooks.hpp"

#include "Json.hpp"

namespace LuminaAgent {

HookDispatcher::HookDispatcher(const RuntimeCallbacks &callbacks)
    : callbacks_(callbacks) {}

std::string HookDispatcher::dispatch(const std::string &lifecycle, const std::string &payload) const {
    if (!callbacks_.hasHook()) {
        return "";
    }
    const std::string event = "{\"lifecycle\":" + jsonString(lifecycle) + ",\"payload\":" + payload + "}";
    return callbacks_.dispatchHook(event);
}

} // namespace LuminaAgent
