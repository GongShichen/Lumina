#pragma once

#include <map>
#include <string>

#include "Json.hpp"

namespace LuminaAgent {

bool validateReActStepObject(const std::string &json, bool requireKnownType, std::string &error);
std::string firstValidReActStepObject(const std::string &text);
std::string reactStepType(const std::map<std::string, JsonField> &fields);

} // namespace LuminaAgent
