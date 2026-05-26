#include "ToolRegistry.hpp"

#include <sstream>

#include "Json.hpp"

namespace LuminaAgent {

static bool isReadOnlySideEffect(const std::string &value) {
    const std::string lowered = lowercased(value);
    return lowered == "readonly" ||
        lowered == "read_only" ||
        lowered == "none" ||
        lowered == "false" ||
        lowered == "read";
}

std::string ToolRegistry::registerSchema(const char *toolSchemaJson) {
    if (toolSchemaJson == nullptr || trim(toolSchemaJson).empty()) {
        return "{\"ok\":false,\"error\":\"missing tool schema JSON.\"}";
    }
    const std::string schema = trim(toolSchemaJson);
    std::map<std::string, JsonField> fields;
    if (!parseFieldsOrEmpty(schema, fields)) {
        return "{\"ok\":false,\"error\":\"tool schema must be a JSON object.\"}";
    }
    const std::string name = stringField(fields, "name");
    if (name.empty()) {
        return "{\"ok\":false,\"error\":\"tool schema requires string field name.\"}";
    }

    std::string sideEffect = stringField(fields, "sideEffect");
    if (sideEffect.empty()) {
        sideEffect = stringField(fields, "side_effect");
    }
    if (sideEffect.empty()) {
        sideEffect = stringField(fields, "effect");
    }

    names_.insert(name);
    readOnly_[name] = isReadOnlySideEffect(sideEffect);
    records_[name] = parseRecord(schema);
    schemas_.push_back(schema);
    return "{\"ok\":true,\"name\":" + jsonString(name) + "}";
}

bool ToolRegistry::contains(const std::string &toolName) const {
    return names_.count(toolName) > 0;
}

bool ToolRegistry::isReadOnly(const std::string &toolName) const {
    auto it = readOnly_.find(toolName);
    return it != readOnly_.end() && it->second;
}

size_t ToolRegistry::toolCount() const {
    return records_.size();
}

std::string ToolRegistry::schemasJson() const {
    std::ostringstream output;
    output << "[";
    for (size_t index = 0; index < schemas_.size(); index++) {
        if (index > 0) {
            output << ",";
        }
        output << schemas_[index];
    }
    output << "]";
    return output.str();
}

std::string ToolRegistry::modelFacingSchemasJson() const {
    std::ostringstream output;
    output << "[";
    size_t index = 0;
    for (const auto &entry : records_) {
        const ToolSchemaRecord &record = entry.second;
        if (index++ > 0) {
            output << ",";
        }
        output << "{"
               << "\"name\":" << jsonString(record.name) << ","
               << "\"purpose\":" << jsonString(record.description) << ","
               << "\"side_effect\":" << jsonString(record.sideEffect) << ","
               << "\"sensitivity\":" << jsonString(record.sensitivity) << ","
               << "\"parameters\":[";
        for (size_t parameterIndex = 0; parameterIndex < record.parameters.size(); parameterIndex++) {
            const Parameter &parameter = record.parameters[parameterIndex];
            if (parameterIndex > 0) {
                output << ",";
            }
            output << "{"
                   << "\"name\":" << jsonString(parameter.name) << ","
                   << "\"type\":" << jsonString(parameter.type) << ","
                   << "\"description\":" << jsonString(parameter.description) << ","
                   << "\"required\":" << jsonBool(parameter.required)
                   << "}";
        }
        output << "]"
               << "}";
    }
    output << "]";
    return output.str();
}

std::string ToolRegistry::capabilityListJson() const {
    std::ostringstream output;
    output << "[";
    size_t index = 0;
    for (const auto &entry : records_) {
        const ToolSchemaRecord &record = entry.second;
        if (index++ > 0) {
            output << ",";
        }
        output << "{"
               << "\"name\":" << jsonString(record.name) << ","
               << "\"purpose\":" << jsonString(truncateToCharacters(record.description, 160)) << ","
               << "\"side_effect\":" << jsonString(record.sideEffect) << ","
               << "\"parameter_names\":[";
        for (size_t parameterIndex = 0; parameterIndex < record.parameters.size(); parameterIndex++) {
            if (parameterIndex > 0) {
                output << ",";
            }
            output << jsonString(record.parameters[parameterIndex].name);
        }
        output << "]"
               << "}";
    }
    output << "]";
    return output.str();
}

std::string ToolRegistry::validateCallJson(const std::string &toolName, const std::string &parametersJson) const {
    auto recordIt = records_.find(toolName);
    if (recordIt == records_.end()) {
        return "{\"ok\":false,\"error\":\"tool is not registered\"}";
    }
    std::map<std::string, JsonField> parameters;
    std::string error;
    if (!parseTopLevelObject(parametersJson.empty() ? "{}" : parametersJson, parameters, error)) {
        return "{\"ok\":false,\"error\":\"tool parameters must be a JSON object: " + escapeJson(error) + "\"}";
    }
    for (const Parameter &parameter : recordIt->second.parameters) {
        auto valueIt = parameters.find(parameter.name);
        if (valueIt == parameters.end()) {
            if (parameter.required) {
                return "{\"ok\":false,\"error\":\"missing required parameter " + escapeJson(parameter.name) + "\"}";
            }
            continue;
        }
        if (!parameterTypeMatches(parameter, valueIt->second)) {
            return "{\"ok\":false,\"error\":\"parameter " + escapeJson(parameter.name) + " has invalid type\"}";
        }
    }
    return "{\"ok\":true}";
}

std::string ToolRegistry::redactedParametersJson(const std::string &toolName, const std::string &parametersJson) const {
    auto recordIt = records_.find(toolName);
    if (recordIt == records_.end()) {
        return parametersJson.empty() ? "{}" : parametersJson;
    }
    std::map<std::string, JsonField> parameters;
    if (!parseFieldsOrEmpty(parametersJson.empty() ? "{}" : parametersJson, parameters)) {
        return "{}";
    }
    std::set<std::string> sensitive;
    for (const Parameter &parameter : recordIt->second.parameters) {
        if (parameter.sensitive) {
            sensitive.insert(parameter.name);
        }
    }
    std::ostringstream output;
    output << "{";
    size_t index = 0;
    for (const auto &entry : parameters) {
        if (index++ > 0) {
            output << ",";
        }
        output << jsonString(entry.first) << ":";
        output << (sensitive.count(entry.first) > 0 ? jsonString("[redacted]") : entry.second.raw);
    }
    output << "}";
    return output.str();
}

ToolRegistry::ToolSchemaRecord ToolRegistry::parseRecord(const std::string &schema) const {
    ToolSchemaRecord record;
    record.raw = schema;
    std::map<std::string, JsonField> fields;
    parseFieldsOrEmpty(schema, fields);
    record.name = stringField(fields, "name");
    record.description = stringField(fields, "description");
    record.sideEffect = stringField(fields, "sideEffect", stringField(fields, "side_effect"));
    record.sensitivity = stringField(fields, "sensitivity");
    for (const std::string &parameterJson : extractObjectArrayItems(rawField(fields, "parameters", "[]"))) {
        std::map<std::string, JsonField> parameterFields;
        parseFieldsOrEmpty(parameterJson, parameterFields);
        Parameter parameter;
        parameter.name = stringField(parameterFields, "name");
        parameter.type = lowercased(stringField(parameterFields, "type"));
        parameter.description = stringField(parameterFields, "description");
        parameter.required = boolField(parameterFields, "required", true);
        parameter.sensitive = boolField(parameterFields, "sensitive", false);
        if (!parameter.name.empty()) {
            record.parameters.push_back(parameter);
        }
    }
    return record;
}

bool ToolRegistry::parameterTypeMatches(const Parameter &parameter, const JsonField &value) const {
    const std::string type = lowercased(parameter.type);
    if (type.empty() || type == "any") {
        return true;
    }
    if (type == "string" || type == "dateiso8601" || type == "date_iso8601") {
        return value.kind == JsonKind::string;
    }
    if (type == "bool" || type == "boolean") {
        return value.kind == JsonKind::boolean;
    }
    if (type == "object") {
        return value.kind == JsonKind::object;
    }
    if (type == "array") {
        return value.kind == JsonKind::array;
    }
    if (type == "number" || type == "integer" || type == "double") {
        return value.kind == JsonKind::other;
    }
    return true;
}

} // namespace LuminaAgent
