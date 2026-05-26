#pragma once

#include <map>
#include <string>
#include <vector>

namespace LuminaAgent {

enum class JsonKind {
    string,
    boolean,
    object,
    array,
    other
};

struct JsonField {
    JsonKind kind = JsonKind::other;
    std::string raw;
    std::string stringValue;
    bool boolValue = false;
};

std::string trim(const std::string &input);
std::string lowercased(std::string value);
std::string escapeJson(const std::string &value);
std::string jsonString(const std::string &value);
std::string jsonBool(bool value);
std::string truncateToCharacters(const std::string &value, int limit);

bool parseTopLevelObject(
    const std::string &json,
    std::map<std::string, JsonField> &fields,
    std::string &error
);

bool parseFieldsOrEmpty(const std::string &json, std::map<std::string, JsonField> &fields);
std::vector<std::string> extractBalancedObjects(const std::string &text);
std::vector<std::string> extractObjectArrayItems(const std::string &arrayJson);

std::string stringField(
    const std::map<std::string, JsonField> &fields,
    const std::string &key,
    const std::string &fallback = ""
);
std::string rawField(
    const std::map<std::string, JsonField> &fields,
    const std::string &key,
    const std::string &fallback = "null"
);
int intField(const std::map<std::string, JsonField> &fields, const std::string &key, int fallback);
bool boolField(const std::map<std::string, JsonField> &fields, const std::string &key, bool fallback);
bool hasOnlyKeys(
    const std::map<std::string, JsonField> &fields,
    const std::vector<std::string> &allowed,
    std::string &error
);

char *copyCString(const std::string &value);
char *successResponse(const std::string &json);
char *failureResponse(const std::string &error);
std::string consumeCString(char *value);

} // namespace LuminaAgent
