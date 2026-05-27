#pragma once

#include <map>
#include <string>

#include "Json.hpp"

namespace LuminaAgent {

// Validates one model-produced JSON object against Lumina's structured ReAct transport.
bool validateReActStepObject(const std::string &json, bool requireKnownType, std::string &error);

// Returns the first valid ReAct step found inside streamed model text.
std::string firstValidReActStepObject(const std::string &text);

// Reads the normalized `type` field from a parsed ReAct object.
std::string reactStepType(const std::map<std::string, JsonField> &fields);

} // namespace LuminaAgent
