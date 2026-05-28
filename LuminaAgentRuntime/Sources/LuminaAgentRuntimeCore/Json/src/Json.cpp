#include "Json.hpp"

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <cstring>
#include <sstream>

namespace LuminaAgent {

std::string trim(const std::string &input) {
    size_t start = 0;
    while (start < input.size() && std::isspace(static_cast<unsigned char>(input[start]))) {
        start++;
    }
    size_t end = input.size();
    while (end > start && std::isspace(static_cast<unsigned char>(input[end - 1]))) {
        end--;
    }
    return input.substr(start, end - start);
}

std::string lowercased(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) {
        return static_cast<char>(std::tolower(c));
    });
    return value;
}

std::string escapeJson(const std::string &value) {
    std::string escaped;
    escaped.reserve(value.size() + 16);
    for (char c : value) {
        switch (c) {
        case '\\': escaped += "\\\\"; break;
        case '"': escaped += "\\\""; break;
        case '\n': escaped += "\\n"; break;
        case '\r': escaped += "\\r"; break;
        case '\t': escaped += "\\t"; break;
        default:
            escaped += static_cast<unsigned char>(c) < 0x20 ? ' ' : c;
        }
    }
    return escaped;
}

std::string jsonString(const std::string &value) {
    return "\"" + escapeJson(value) + "\"";
}

std::string jsonBool(bool value) {
    return value ? "true" : "false";
}

std::string truncateToCharacters(const std::string &value, int limit) {
    if (limit <= 0 || static_cast<int>(value.size()) <= limit) {
        return value;
    }
    if (limit <= 16) {
        return value.substr(0, static_cast<size_t>(limit));
    }
    return value.substr(0, static_cast<size_t>(limit - 12)) + "\n...[truncated]";
}

static void skipWhitespace(const std::string &text, size_t &index) {
    while (index < text.size() && std::isspace(static_cast<unsigned char>(text[index]))) {
        index++;
    }
}

static bool parseJsonString(const std::string &text, size_t &index, std::string &decoded, std::string &error) {
    if (index >= text.size() || text[index] != '"') {
        error = "expected JSON string.";
        return false;
    }
    index++;
    decoded.clear();
    while (index < text.size()) {
        const char c = text[index++];
        if (c == '"') {
            return true;
        }
        if (c == '\\') {
            if (index >= text.size()) {
                error = "unterminated string escape.";
                return false;
            }
            const char escaped = text[index++];
            switch (escaped) {
            case '"':
            case '\\':
            case '/':
                decoded += escaped;
                break;
            case 'b': decoded += '\b'; break;
            case 'f': decoded += '\f'; break;
            case 'n': decoded += '\n'; break;
            case 'r': decoded += '\r'; break;
            case 't': decoded += '\t'; break;
            case 'u':
                if (index + 4 > text.size()) {
                    error = "incomplete unicode escape.";
                    return false;
                }
                decoded += "\\u" + text.substr(index, 4);
                index += 4;
                break;
            default:
                error = "invalid string escape.";
                return false;
            }
        } else {
            decoded += c;
        }
    }
    error = "unterminated JSON string.";
    return false;
}

static bool skipStringValue(const std::string &text, size_t &index, std::string &error) {
    std::string ignored;
    return parseJsonString(text, index, ignored, error);
}

static bool skipBalanced(const std::string &text, size_t &index, char open, char close, std::string &error) {
    if (index >= text.size() || text[index] != open) {
        error = "expected balanced JSON value.";
        return false;
    }
    int depth = 0;
    while (index < text.size()) {
        const char c = text[index];
        if (c == '"') {
            if (!skipStringValue(text, index, error)) {
                return false;
            }
            continue;
        }
        if (c == open) {
            depth++;
        } else if (c == close) {
            depth--;
            index++;
            if (depth == 0) {
                return true;
            }
            continue;
        }
        index++;
    }
    error = "unterminated balanced JSON value.";
    return false;
}

static bool skipJsonValue(const std::string &text, size_t &index, std::string &error, JsonField &field) {
    skipWhitespace(text, index);
    const size_t start = index;
    if (index >= text.size()) {
        error = "missing JSON value.";
        return false;
    }

    if (text[index] == '"') {
        field.kind = JsonKind::string;
        if (!parseJsonString(text, index, field.stringValue, error)) {
            return false;
        }
        field.raw = text.substr(start, index - start);
        return true;
    }
    if (text[index] == '{') {
        field.kind = JsonKind::object;
        if (!skipBalanced(text, index, '{', '}', error)) {
            return false;
        }
        field.raw = text.substr(start, index - start);
        return true;
    }
    if (text[index] == '[') {
        field.kind = JsonKind::array;
        if (!skipBalanced(text, index, '[', ']', error)) {
            return false;
        }
        field.raw = text.substr(start, index - start);
        return true;
    }
    if (text.compare(index, 4, "true") == 0) {
        field.kind = JsonKind::boolean;
        field.boolValue = true;
        index += 4;
        field.raw = "true";
        return true;
    }
    if (text.compare(index, 5, "false") == 0) {
        field.kind = JsonKind::boolean;
        field.boolValue = false;
        index += 5;
        field.raw = "false";
        return true;
    }

    while (index < text.size()) {
        const char c = text[index];
        if (c == ',' || c == '}' || std::isspace(static_cast<unsigned char>(c))) {
            break;
        }
        index++;
    }
    if (index == start) {
        error = "invalid JSON value.";
        return false;
    }
    field.kind = JsonKind::other;
    field.raw = text.substr(start, index - start);
    return true;
}

bool parseTopLevelObject(
    const std::string &json,
    std::map<std::string, JsonField> &fields,
    std::string &error
) {
    fields.clear();
    const std::string object = trim(json);
    size_t index = 0;
    skipWhitespace(object, index);
    if (index >= object.size() || object[index] != '{') {
        error = "top-level value must be an object.";
        return false;
    }
    index++;
    skipWhitespace(object, index);
    if (index < object.size() && object[index] == '}') {
        index++;
        skipWhitespace(object, index);
        if (index != object.size()) {
            error = "unexpected trailing content.";
            return false;
        }
        return true;
    }

    while (index < object.size()) {
        skipWhitespace(object, index);
        std::string key;
        if (!parseJsonString(object, index, key, error)) {
            return false;
        }
        skipWhitespace(object, index);
        if (index >= object.size() || object[index] != ':') {
            error = "expected ':' after object key.";
            return false;
        }
        index++;
        JsonField field;
        if (!skipJsonValue(object, index, error, field)) {
            return false;
        }
        fields[key] = field;
        skipWhitespace(object, index);
        if (index < object.size() && object[index] == ',') {
            index++;
            continue;
        }
        if (index < object.size() && object[index] == '}') {
            index++;
            skipWhitespace(object, index);
            if (index != object.size()) {
                error = "unexpected trailing content.";
                return false;
            }
            return true;
        }
        error = "expected ',' or '}' in object.";
        return false;
    }
    error = "unterminated top-level object.";
    return false;
}

bool parseFieldsOrEmpty(const std::string &json, std::map<std::string, JsonField> &fields) {
    std::string error;
    return parseTopLevelObject(json, fields, error);
}

std::vector<std::string> extractBalancedObjects(const std::string &text) {
    std::vector<std::string> objects;
    size_t start = 0;
    bool hasStart = false;
    int depth = 0;
    bool insideString = false;
    bool escaped = false;

    for (size_t index = 0; index < text.size(); index++) {
        const char c = text[index];
        if (insideString) {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                insideString = false;
            }
            continue;
        }
        if (c == '"') {
            insideString = true;
        } else if (c == '{') {
            if (depth == 0) {
                start = index;
                hasStart = true;
            }
            depth++;
        } else if (c == '}') {
            depth--;
            if (depth == 0 && hasStart) {
                objects.push_back(trim(text.substr(start, index - start + 1)));
                hasStart = false;
            }
            if (depth < 0) {
                depth = 0;
                hasStart = false;
            }
        }
    }
    return objects;
}

std::vector<std::string> extractObjectArrayItems(const std::string &arrayJson) {
    return extractBalancedObjects(arrayJson);
}

std::string stringField(const std::map<std::string, JsonField> &fields, const std::string &key, const std::string &fallback) {
    auto it = fields.find(key);
    if (it == fields.end() || it->second.kind != JsonKind::string) {
        return fallback;
    }
    return it->second.stringValue;
}

std::string rawField(const std::map<std::string, JsonField> &fields, const std::string &key, const std::string &fallback) {
    auto it = fields.find(key);
    if (it == fields.end() || it->second.raw.empty()) {
        return fallback;
    }
    return it->second.raw;
}

int intField(const std::map<std::string, JsonField> &fields, const std::string &key, int fallback) {
    auto it = fields.find(key);
    if (it == fields.end() || it->second.raw.empty()) {
        return fallback;
    }
    try {
        return std::stoi(it->second.raw);
    } catch (...) {
        return fallback;
    }
}

bool boolField(const std::map<std::string, JsonField> &fields, const std::string &key, bool fallback) {
    auto it = fields.find(key);
    if (it == fields.end() || it->second.kind != JsonKind::boolean) {
        return fallback;
    }
    return it->second.boolValue;
}

static std::string canonicalizeJsonValue(const JsonField &field) {
    if (field.kind == JsonKind::object) {
        return canonicalizeJsonObject(field.raw);
    }
    return trim(field.raw);
}

std::string canonicalizeJsonObject(const std::string &json) {
    const std::string text = trim(json.empty() ? "{}" : json);
    std::map<std::string, JsonField> fields;
    std::string error;
    if (!parseTopLevelObject(text, fields, error)) {
        return text;
    }
    std::ostringstream output;
    output << "{";
    size_t index = 0;
    for (const auto &entry : fields) {
        if (index++ > 0) {
            output << ",";
        }
        output << jsonString(entry.first) << ":" << canonicalizeJsonValue(entry.second);
    }
    output << "}";
    return output.str();
}

bool hasOnlyKeys(
    const std::map<std::string, JsonField> &fields,
    const std::vector<std::string> &allowed,
    std::string &error
) {
    std::vector<std::string> unknown;
    for (const auto &entry : fields) {
        if (std::find(allowed.begin(), allowed.end(), entry.first) == allowed.end()) {
            unknown.push_back(entry.first);
        }
    }
    if (!unknown.empty()) {
        std::sort(unknown.begin(), unknown.end());
        error = "unknown top-level keys: ";
        for (size_t index = 0; index < unknown.size(); index++) {
            if (index > 0) {
                error += ", ";
            }
            error += unknown[index];
        }
        error += ".";
        return false;
    }
    return true;
}

char *copyCString(const std::string &value) {
    char *result = static_cast<char *>(std::malloc(value.size() + 1));
    if (result == nullptr) {
        return nullptr;
    }
    std::memcpy(result, value.c_str(), value.size() + 1);
    return result;
}

char *successResponse(const std::string &json) {
    return copyCString("{\"ok\":true,\"json\":\"" + escapeJson(json) + "\"}");
}

char *failureResponse(const std::string &error) {
    return copyCString("{\"ok\":false,\"error\":\"" + escapeJson(error) + "\"}");
}

std::string consumeCString(char *value) {
    if (value == nullptr) {
        return "";
    }
    std::string result(value);
    std::free(value);
    return result;
}

} // namespace LuminaAgent
