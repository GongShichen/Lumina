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

// Removes leading and trailing ASCII whitespace from a JSON/text fragment.
std::string trim(const std::string &input);

// Lowercases ASCII characters for protocol enum comparison.
std::string lowercased(std::string value);

// Escapes a string for safe insertion inside JSON string literals.
std::string escapeJson(const std::string &value);

// Wraps and escapes a C++ string as a JSON string literal.
std::string jsonString(const std::string &value);

// Serializes a boolean as JSON `true` or `false`.
std::string jsonBool(bool value);

// Truncates long human-readable text without splitting runtime contracts.
std::string truncateToCharacters(const std::string &value, int limit);

// Parses a top-level JSON object into raw fields and reports malformed input.
bool parseTopLevelObject(
    const std::string &json,
    std::map<std::string, JsonField> &fields,
    std::string &error
);

// Parses a JSON object and returns an empty map on invalid input.
bool parseFieldsOrEmpty(const std::string &json, std::map<std::string, JsonField> &fields);

// Extracts balanced top-level JSON objects from arbitrary model text.
std::vector<std::string> extractBalancedObjects(const std::string &text);

// Extracts object entries from a top-level JSON array.
std::vector<std::string> extractObjectArrayItems(const std::string &arrayJson);

// Reads a string field or returns the provided fallback.
std::string stringField(
    const std::map<std::string, JsonField> &fields,
    const std::string &key,
    const std::string &fallback = ""
);

// Reads a raw JSON field or returns the provided fallback JSON fragment.
std::string rawField(
    const std::map<std::string, JsonField> &fields,
    const std::string &key,
    const std::string &fallback = "null"
);

// Reads an integer field from a raw numeric JSON fragment.
int intField(const std::map<std::string, JsonField> &fields, const std::string &key, int fallback);

// Reads a boolean field or returns the provided fallback.
bool boolField(const std::map<std::string, JsonField> &fields, const std::string &key, bool fallback);

// Verifies that a parsed object contains only known protocol keys.
bool hasOnlyKeys(
    const std::map<std::string, JsonField> &fields,
    const std::vector<std::string> &allowed,
    std::string &error
);

// Allocates a C string owned by the runtime C ABI.
char *copyCString(const std::string &value);

// Allocates a normalized success JSON response containing a raw JSON payload.
char *successResponse(const std::string &json);

// Allocates a normalized failure JSON response with an error string.
char *failureResponse(const std::string &error);

// Copies then releases a runtime-allocated C string returned by a callback.
std::string consumeCString(char *value);

} // namespace LuminaAgent
