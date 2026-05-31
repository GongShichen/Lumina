#include "Hooks.hpp"

#include <vector>

#include "Json.hpp"

namespace LuminaAgent {

HookDispatcher::HookDispatcher(const RuntimeCallbacks &callbacks)
    : callbacks_(callbacks) {}

static void appendDirectiveObjects(std::vector<std::string> &directives, const std::string &directiveJson) {
    const std::string text = trim(directiveJson);
    if (text.empty() || text == "{}" || text == "null") {
        return;
    }
    std::map<std::string, JsonField> fields;
    if (parseFieldsOrEmpty(text, fields)) {
        const std::string nested = rawField(fields, "directives", "");
        if (!nested.empty()) {
            const std::vector<std::string> items = extractObjectArrayItems(nested);
            directives.insert(directives.end(), items.begin(), items.end());
            return;
        }
    }
    directives.push_back(text);
}

std::string HookDispatcher::dispatch(const std::string &lifecycle, const std::string &payload) const {
    if (!callbacks_.hasHook()) {
        return "";
    }
    const std::vector<std::string> routeIds = callbacks_.matchingHookRouteIds(lifecycle, payload);
    if (!routeIds.empty()) {
        std::vector<std::string> directives;
        for (const std::string &routeId : routeIds) {
            const std::string event = "{\"route_id\":" + jsonString(routeId) +
                ",\"lifecycle\":" + jsonString(lifecycle) +
                ",\"payload\":" + payload + "}";
            appendDirectiveObjects(directives, callbacks_.dispatchHook(event));
        }
        if (directives.empty()) {
            return "{}";
        }
        std::string output = "{\"directives\":[";
        for (size_t index = 0; index < directives.size(); index++) {
            if (index > 0) {
                output += ",";
            }
            output += directives[index];
        }
        output += "]}";
        return output;
    }
    const std::string event = "{\"lifecycle\":" + jsonString(lifecycle) + ",\"payload\":" + payload + "}";
    return callbacks_.dispatchHook(event);
}

static void mergeDirective(RuntimeHookDirectives &target, const std::string &json) {
    std::map<std::string, JsonField> fields;
    if (!parseFieldsOrEmpty(json, fields)) {
        return;
    }

    std::string type = lowercased(stringField(fields, "type"));
    if (type.empty()) {
        if (boolField(fields, "terminate", false)) {
            type = "fail";
        } else if (boolField(fields, "require_confirmation", false)) {
            type = "require_confirmation";
        }
    }

    if (type == "fail" || type == "terminate" || type == "tripwire_failure") {
        target.hasFail = true;
        target.reason = stringField(fields, "reason", stringField(fields, "message", "hook failed run"));
        target.markdown = stringField(fields, "markdown", stringField(fields, "content", "### 已终止\n\nRuntime hook stopped this run."));
        return;
    }
    if (type == "pause") {
        target.hasPause = true;
        target.reason = stringField(fields, "reason", "hook paused run");
        target.pauseKind = stringField(fields, "kind", "hook");
        target.pausePayloadJson = rawField(fields, "payload", "{}");
        return;
    }
    if (type == "reject_tool_call") {
        target.hasRejectToolCall = true;
        target.reason = stringField(fields, "reason", stringField(fields, "message", "tool call rejected by hook"));
        return;
    }
    if (type == "rewrite_tool_call") {
        target.hasRewriteToolCall = true;
        target.rewrittenToolName = stringField(fields, "tool_name", stringField(fields, "toolName"));
        target.rewrittenParametersJson = rawField(fields, "parameters", "{}");
        target.requiresConfirmation = boolField(fields, "requires_confirmation", boolField(fields, "requiresConfirmation", target.requiresConfirmation));
        return;
    }
    if (type == "require_confirmation") {
        target.requiresConfirmation = true;
        if (target.reason.empty()) {
            target.reason = stringField(fields, "reason", "hook requires confirmation");
        }
        return;
    }
    if (type == "append_context") {
        target.hasAppendContext = true;
        target.appendedContextJson = rawField(fields, "context", rawField(fields, "payload", "{}"));
    }
}

RuntimeHookDirectives parseRuntimeHookDirectives(const std::string &directiveJson) {
    RuntimeHookDirectives result;
    const std::string text = trim(directiveJson);
    if (text.empty() || text == "{}" || text == "null") {
        return result;
    }

    std::map<std::string, JsonField> fields;
    if (!parseFieldsOrEmpty(text, fields)) {
        return result;
    }

    const std::string directives = rawField(fields, "directives", "");
    if (!directives.empty()) {
        for (const std::string &item : extractObjectArrayItems(directives)) {
            mergeDirective(result, item);
        }
        return result;
    }

    mergeDirective(result, text);
    return result;
}

} // namespace LuminaAgent
