#pragma once

#include <map>
#include <string>

#include "Json.hpp"

namespace LuminaAgent {

// Validates one canonical runtime ReAct object after MiniCPM extraction or trusted adapter conversion.
bool validateReActStepObject(const std::string &json, bool requireKnownType, std::string &error);

// Returns the first valid canonical ReAct step found inside trusted adapter text.
std::string firstValidReActStepObject(const std::string &text);

// Normalizes MiniCPM-V4.6 special-token model text into the canonical runtime ReAct JSON contract.
// Default local model dialect: minicpm_v46_tool_calls.
std::string normalizeReActStepText(const std::string &text, const std::string &dialect, std::string &error);

// Reads the normalized `type` field from a parsed ReAct object.
std::string reactStepType(const std::map<std::string, JsonField> &fields);

} // namespace LuminaAgent
