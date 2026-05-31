#pragma once

#include <map>
#include <set>
#include <string>
#include <vector>

#include "Json.hpp"

namespace LuminaAgent {

class ToolRegistry {
public:
    // Registers one caller-owned capability schema and stores a normalized view.
    std::string registerSchema(const char *toolSchemaJson);

    // Looks up registered capabilities by their stable tool name.
    bool contains(const std::string &toolName) const;
    bool isReadOnly(const std::string &toolName) const;
    bool isConcurrencySafe(const std::string &toolName) const;
    bool requiresUserInteraction(const std::string &toolName) const;
    std::string sideEffect(const std::string &toolName) const;
    std::string sensitivity(const std::string &toolName) const;
    bool isDestructive(const std::string &toolName) const;
    std::string interruptBehavior(const std::string &toolName) const;
    std::string idempotencyPolicy(const std::string &toolName) const;
    int maxResultSizeCharacters(const std::string &toolName) const;
    size_t toolCount() const;

    // Returns raw schemas for debugging/export and compact schemas for model prompts.
    std::string schemasJson() const;
    std::string modelFacingSchemasJson() const;
    std::string capabilityListJson() const;
    std::string nameOnlyListJson() const;
    std::string discoverToolsJson(const std::string &query, const std::string &category, int maxResults, bool includeSchemas) const;

    // Validates model-provided parameters against required fields and basic types.
    std::string validateCallJson(const std::string &toolName, const std::string &parametersJson) const;
    std::string validateResultJson(const std::string &toolName, const std::string &resultJson) const;

    // Redacts sensitive parameter values before audit/event/debug export.
    std::string redactedParametersJson(const std::string &toolName, const std::string &parametersJson) const;
    std::string truncateResultContent(const std::string &toolName, const std::string &content) const;

private:
    struct Parameter {
        std::string name;
        std::string type;
        std::string description;
        std::string enumJson;
        std::string pattern;
        std::string minimumRaw;
        std::string maximumRaw;
        bool required = true;
        bool sensitive = false;
    };
    struct ToolSchemaRecord {
        std::string raw;
        std::string name;
        std::string description;
        std::string category;
        std::string searchHint;
        std::string sideEffect;
        std::string sensitivity;
        std::string interruptBehavior;
        std::string idempotencyPolicy;
        std::string inputSchema;
        std::string outputSchema;
        std::string displaySummary;
        bool destructive = false;
        bool concurrencySafe = false;
        bool requiresUserInteraction = false;
        bool strict = false;
        int maxResultSize = 0;
        std::vector<std::string> aliases;
        std::vector<Parameter> parameters;
    };

    ToolSchemaRecord parseRecord(const std::string &schema) const;
    bool parameterTypeMatches(const Parameter &parameter, const JsonField &value) const;
    bool parameterEnumMatches(const Parameter &parameter, const JsonField &value) const;
    std::string compactRecordJson(const ToolSchemaRecord &record, bool includeSchema) const;
    bool recordMatches(const ToolSchemaRecord &record, const std::string &query, const std::string &category) const;

    std::vector<std::string> schemas_;
    std::map<std::string, ToolSchemaRecord> records_;
    std::set<std::string> names_;
    std::map<std::string, bool> readOnly_;
};

} // namespace LuminaAgent
