#include "ToolRegistry.hpp"

#include <cctype>
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

static std::vector<std::string> extractStringArrayItems(const std::string &arrayJson) {
    std::vector<std::string> values;
    const std::string text = trim(arrayJson);
    if (text.size() < 2 || text.front() != '[' || text.back() != ']') {
        return values;
    }
    size_t index = 1;
    while (index + 1 < text.size()) {
        while (index < text.size() && (std::isspace(static_cast<unsigned char>(text[index])) || text[index] == ',')) {
            index++;
        }
        if (index >= text.size() || text[index] != '"') {
            index++;
            continue;
        }
        size_t start = index;
        bool escaped = false;
        index++;
        while (index < text.size()) {
            if (escaped) {
                escaped = false;
            } else if (text[index] == '\\') {
                escaped = true;
            } else if (text[index] == '"') {
                index++;
                std::map<std::string, JsonField> object;
                if (parseFieldsOrEmpty("{\"value\":" + text.substr(start, index - start) + "}", object)) {
                    values.push_back(stringField(object, "value"));
                }
                break;
            }
            index++;
        }
    }
    return values;
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
    ToolSchemaRecord record = parseRecord(schema);
    readOnly_[name] = isReadOnlySideEffect(record.sideEffect) || boolField(fields, "readOnly", false);
    records_[name] = record;
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

bool ToolRegistry::isConcurrencySafe(const std::string &toolName) const {
    auto it = records_.find(toolName);
    return it != records_.end() && it->second.concurrencySafe;
}

bool ToolRegistry::requiresUserInteraction(const std::string &toolName) const {
    auto it = records_.find(toolName);
    return it != records_.end() && it->second.requiresUserInteraction;
}

std::string ToolRegistry::interruptBehavior(const std::string &toolName) const {
    auto it = records_.find(toolName);
    return it == records_.end() ? "" : it->second.interruptBehavior;
}

std::string ToolRegistry::idempotencyPolicy(const std::string &toolName) const {
    auto it = records_.find(toolName);
    return it == records_.end() || it->second.idempotencyPolicy.empty()
        ? "replay_identical"
        : it->second.idempotencyPolicy;
}

int ToolRegistry::maxResultSizeCharacters(const std::string &toolName) const {
    auto it = records_.find(toolName);
    return it == records_.end() ? 0 : it->second.maxResultSize;
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
        output << compactRecordJson(record, true);
    }
    output << "]";
    return output.str();
}

std::string ToolRegistry::compactRecordJson(const ToolSchemaRecord &record, bool includeSchema) const {
    std::ostringstream output;
    output << "{"
           << "\"name\":" << jsonString(record.name) << ","
           << "\"purpose\":" << jsonString(record.description) << ","
           << "\"category\":" << jsonString(record.category) << ","
           << "\"search_hint\":" << jsonString(record.searchHint) << ","
           << "\"side_effect\":" << jsonString(record.sideEffect) << ","
           << "\"read_only\":" << jsonBool(isReadOnly(record.name)) << ","
           << "\"destructive\":" << jsonBool(record.destructive) << ","
           << "\"concurrency_safe\":" << jsonBool(record.concurrencySafe) << ","
           << "\"requires_user_interaction\":" << jsonBool(record.requiresUserInteraction) << ","
           << "\"interrupt_behavior\":" << jsonString(record.interruptBehavior) << ","
           << "\"idempotency_policy\":" << jsonString(record.idempotencyPolicy) << ","
           << "\"sensitivity\":" << jsonString(record.sensitivity) << ","
           << "\"aliases\":[";
    for (size_t aliasIndex = 0; aliasIndex < record.aliases.size(); aliasIndex++) {
        if (aliasIndex > 0) {
            output << ",";
        }
        output << jsonString(record.aliases[aliasIndex]);
    }
    output << "],\"parameters\":[";
        for (size_t parameterIndex = 0; parameterIndex < record.parameters.size(); parameterIndex++) {
            const Parameter &parameter = record.parameters[parameterIndex];
            if (parameterIndex > 0) {
                output << ",";
            }
            output << "{"
                   << "\"name\":" << jsonString(parameter.name) << ","
                   << "\"type\":" << jsonString(parameter.type) << ","
                   << "\"description\":" << jsonString(parameter.description) << ","
                   << "\"required\":" << jsonBool(parameter.required) << ","
                   << "\"sensitive\":" << jsonBool(parameter.sensitive)
                   << "}";
        }
    output << "]";
    if (includeSchema) {
        output << ",\"strict\":" << jsonBool(record.strict)
               << ",\"input_schema\":" << (record.inputSchema.empty() ? "null" : record.inputSchema)
               << ",\"output_schema\":" << (record.outputSchema.empty() ? "null" : record.outputSchema)
               << ",\"display_summary\":" << jsonString(record.displaySummary);
    }
    output << "}";
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
               << "\"category\":" << jsonString(record.category) << ","
               << "\"search_hint\":" << jsonString(truncateToCharacters(record.searchHint, 120)) << ","
               << "\"side_effect\":" << jsonString(record.sideEffect) << ","
               << "\"read_only\":" << jsonBool(isReadOnly(record.name)) << ","
               << "\"destructive\":" << jsonBool(record.destructive) << ","
               << "\"requires_user_interaction\":" << jsonBool(record.requiresUserInteraction) << ","
               << "\"idempotency_policy\":" << jsonString(record.idempotencyPolicy) << ","
               << "\"aliases\":[";
        for (size_t aliasIndex = 0; aliasIndex < record.aliases.size(); aliasIndex++) {
            if (aliasIndex > 0) {
                output << ",";
            }
            output << jsonString(record.aliases[aliasIndex]);
        }
        output << "],\"parameter_names\":[";
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

std::string ToolRegistry::discoverToolsJson(const std::string &query, const std::string &category, int maxResults, bool includeSchemas) const {
    const int safeMax = maxResults <= 0 ? static_cast<int>(records_.size()) : maxResults;
    std::ostringstream output;
    output << "{\"matches\":[";
    int emitted = 0;
    for (const auto &entry : records_) {
        if (!recordMatches(entry.second, query, category)) {
            continue;
        }
        if (emitted > 0) {
            output << ",";
        }
        output << compactRecordJson(entry.second, includeSchemas);
        emitted += 1;
        if (emitted >= safeMax) {
            break;
        }
    }
    output << "],\"query\":" << jsonString(query)
           << ",\"category\":" << jsonString(category)
           << ",\"total_tools\":" << records_.size()
           << "}";
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
        if (!parameterEnumMatches(parameter, valueIt->second)) {
            return "{\"ok\":false,\"error\":\"parameter " + escapeJson(parameter.name) + " is not in the allowed enum\"}";
        }
    }
    return "{\"ok\":true}";
}

std::string ToolRegistry::validateResultJson(const std::string &toolName, const std::string &resultJson) const {
    if (!contains(toolName)) {
        return "{\"ok\":false,\"error\":\"tool is not registered\"}";
    }
    std::map<std::string, JsonField> fields;
    std::string error;
    if (!parseTopLevelObject(trim(resultJson).empty() ? "{}" : resultJson, fields, error)) {
        return "{\"ok\":false,\"error\":\"tool result must be a JSON object: " + escapeJson(error) + "\"}";
    }
    if (fields.find("status") == fields.end()) {
        return "{\"ok\":false,\"error\":\"tool result requires status\"}";
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

std::string ToolRegistry::truncateResultContent(const std::string &toolName, const std::string &content) const {
    const int limit = maxResultSizeCharacters(toolName);
    return limit > 0 ? truncateToCharacters(content, limit) : content;
}

ToolRegistry::ToolSchemaRecord ToolRegistry::parseRecord(const std::string &schema) const {
    ToolSchemaRecord record;
    record.raw = schema;
    std::map<std::string, JsonField> fields;
    parseFieldsOrEmpty(schema, fields);
    record.name = stringField(fields, "name");
    record.description = stringField(fields, "description");
    record.category = stringField(fields, "category");
    record.searchHint = stringField(fields, "searchHint", stringField(fields, "search_hint"));
    record.sideEffect = stringField(fields, "sideEffect", stringField(fields, "side_effect"));
    record.sensitivity = stringField(fields, "sensitivity");
    record.interruptBehavior = stringField(fields, "interruptBehavior", stringField(fields, "interrupt_behavior"));
    record.idempotencyPolicy = lowercased(stringField(fields, "idempotencyPolicy", stringField(fields, "idempotency_policy", "replay_identical")));
    if (record.idempotencyPolicy != "replay_identical" &&
        record.idempotencyPolicy != "always_execute" &&
        record.idempotencyPolicy != "caller_keyed") {
        record.idempotencyPolicy = "replay_identical";
    }
    record.inputSchema = rawField(fields, "inputSchema", rawField(fields, "input_schema", ""));
    record.outputSchema = rawField(fields, "outputSchema", rawField(fields, "output_schema", ""));
    record.displaySummary = stringField(fields, "displaySummary", stringField(fields, "display_summary"));
    record.destructive = boolField(fields, "destructive", false);
    record.concurrencySafe = boolField(fields, "concurrencySafe", boolField(fields, "concurrency_safe", false));
    record.requiresUserInteraction = boolField(fields, "requiresUserInteraction", boolField(fields, "requires_user_interaction", false));
    record.strict = boolField(fields, "strict", false);
    record.maxResultSize = intField(fields, "maxResultSize", intField(fields, "max_result_size", 0));
    record.aliases = extractStringArrayItems(rawField(fields, "aliases", "[]"));
    for (const std::string &parameterJson : extractObjectArrayItems(rawField(fields, "parameters", "[]"))) {
        std::map<std::string, JsonField> parameterFields;
        parseFieldsOrEmpty(parameterJson, parameterFields);
        Parameter parameter;
        parameter.name = stringField(parameterFields, "name");
        parameter.type = lowercased(stringField(parameterFields, "type"));
        parameter.description = stringField(parameterFields, "description");
        parameter.enumJson = rawField(parameterFields, "enum", "");
        parameter.pattern = stringField(parameterFields, "pattern");
        parameter.minimumRaw = rawField(parameterFields, "minimum", "");
        parameter.maximumRaw = rawField(parameterFields, "maximum", "");
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

bool ToolRegistry::parameterEnumMatches(const Parameter &parameter, const JsonField &value) const {
    if (parameter.enumJson.empty()) {
        return true;
    }
    const std::vector<std::string> values = extractStringArrayItems(parameter.enumJson);
    if (values.empty() || value.kind != JsonKind::string) {
        return true;
    }
    for (const std::string &allowed : values) {
        if (allowed == value.stringValue) {
            return true;
        }
    }
    return false;
}

bool ToolRegistry::recordMatches(const ToolSchemaRecord &record, const std::string &query, const std::string &category) const {
    const std::string normalizedCategory = lowercased(category);
    if (!normalizedCategory.empty() && lowercased(record.category) != normalizedCategory) {
        return false;
    }
    const std::string normalizedQuery = lowercased(query);
    if (normalizedQuery.empty()) {
        return true;
    }
    std::string haystack = lowercased(record.name + " " + record.description + " " + record.searchHint + " " + record.category);
    for (const std::string &alias : record.aliases) {
        haystack += " " + lowercased(alias);
    }
    return haystack.find(normalizedQuery) != std::string::npos;
}

} // namespace LuminaAgent
