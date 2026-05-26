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
    size_t toolCount() const;

    // Returns raw schemas for debugging/export and compact schemas for model prompts.
    std::string schemasJson() const;
    std::string modelFacingSchemasJson() const;
    std::string capabilityListJson() const;

    // Validates model-provided parameters against required fields and basic types.
    std::string validateCallJson(const std::string &toolName, const std::string &parametersJson) const;

    // Redacts sensitive parameter values before audit/event/debug export.
    std::string redactedParametersJson(const std::string &toolName, const std::string &parametersJson) const;

private:
    struct Parameter {
        std::string name;
        std::string type;
        std::string description;
        bool required = true;
        bool sensitive = false;
    };
    struct ToolSchemaRecord {
        std::string raw;
        std::string name;
        std::string description;
        std::string sideEffect;
        std::string sensitivity;
        std::vector<Parameter> parameters;
    };

    ToolSchemaRecord parseRecord(const std::string &schema) const;
    bool parameterTypeMatches(const Parameter &parameter, const JsonField &value) const;

    std::vector<std::string> schemas_;
    std::map<std::string, ToolSchemaRecord> records_;
    std::set<std::string> names_;
    std::map<std::string, bool> readOnly_;
};

} // namespace LuminaAgent
