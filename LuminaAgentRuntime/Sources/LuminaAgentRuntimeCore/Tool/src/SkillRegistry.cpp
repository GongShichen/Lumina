#include "SkillRegistry.hpp"

#include <algorithm>
#include <cctype>
#include <sstream>

namespace LuminaAgent {

static constexpr int kMaxListingDescriptionCharacters = 250;
static constexpr double kSkillListingBudgetPct = 0.01;
static constexpr int kCharsPerTokenEstimate = 4;

static bool startsWithPath(const std::string &path, const std::string &prefix) {
    if (path.empty() || prefix.empty()) {
        return true;
    }
    if (path == prefix) {
        return true;
    }
    return path.size() > prefix.size() &&
        path.compare(0, prefix.size(), prefix) == 0 &&
        (prefix.back() == '/' || path[prefix.size()] == '/');
}

static int sourcePriority(const std::string &source) {
    const std::string value = lowercased(source);
    if (value == "user") {
        return 0;
    }
    if (value == "project") {
        return 1;
    }
    if (value == "bundled") {
        return 2;
    }
    return 99;
}

static std::string compactWhitespace(const std::string &text) {
    std::string output;
    bool lastWasSpace = false;
    for (char character : text) {
        const bool isSpace = std::isspace(static_cast<unsigned char>(character));
        if (isSpace) {
            if (!lastWasSpace && !output.empty()) {
                output.push_back(' ');
            }
            lastWasSpace = true;
            continue;
        }
        output.push_back(character);
        lastWasSpace = false;
    }
    return trim(output);
}

static std::string clipText(const std::string &text, int limit) {
    const std::string compacted = compactWhitespace(text);
    if (limit <= 0) {
        return "";
    }
    if (static_cast<int>(compacted.size()) <= limit) {
        return compacted;
    }
    if (limit <= 3) {
        return std::string(static_cast<size_t>(limit), '.');
    }
    return compacted.substr(0, static_cast<size_t>(limit - 3)) + "...";
}

static std::vector<std::string> splitTerms(const std::string &query) {
    std::vector<std::string> terms;
    std::string current;
    for (char character : query) {
        if (character == ',' || std::isspace(static_cast<unsigned char>(character))) {
            const std::string term = trim(current);
            if (!term.empty()) {
                terms.push_back(lowercased(term));
            }
            current.clear();
        } else {
            current.push_back(character);
        }
    }
    const std::string term = trim(current);
    if (!term.empty()) {
        terms.push_back(lowercased(term));
    }
    return terms;
}

std::string SkillRegistry::registerMetadata(const char *skillMetadataJson) {
    if (skillMetadataJson == nullptr || trim(skillMetadataJson).empty()) {
        return "{\"ok\":false,\"error\":\"missing skill metadata JSON\"}";
    }
    const std::string metadata = trim(skillMetadataJson);
    std::map<std::string, JsonField> fields;
    if (!parseFieldsOrEmpty(metadata, fields)) {
        return "{\"ok\":false,\"error\":\"skill metadata must be a JSON object\"}";
    }
    SkillRecord record = parseRecord(metadata);
    if (record.canonicalName.empty()) {
        return "{\"ok\":false,\"error\":\"skill metadata requires canonicalName or name\"}";
    }
    for (SkillRecord &existing : records_) {
        if (existing.canonicalName == record.canonicalName) {
            existing = record;
            return "{\"ok\":true,\"name\":" + jsonString(record.canonicalName) + ",\"replaced\":true}";
        }
    }
    records_.push_back(record);
    return "{\"ok\":true,\"name\":" + jsonString(record.canonicalName) + ",\"replaced\":false}";
}

std::string SkillRegistry::discoverSkillsJson(
    const std::string &query,
    int maxResults,
    int contextWindowTokens,
    const std::string &cwd
) const {
    std::vector<SkillRecord> matches;
    for (const SkillRecord &record : visibleRecords(cwd)) {
        if (this->matches(record, query)) {
            matches.push_back(record);
        }
    }
    if (maxResults > 0 && static_cast<int>(matches.size()) > maxResults) {
        matches.resize(static_cast<size_t>(maxResults));
    }
    std::ostringstream output;
    output << "{\"ok\":true,\"matches\":[";
    for (size_t index = 0; index < matches.size(); index++) {
        if (index > 0) {
            output << ",";
        }
        const SkillRecord &record = matches[index];
        output << "{"
               << "\"name\":" << jsonString(record.canonicalName) << ","
               << "\"description\":" << jsonString(record.description) << ","
               << "\"when_to_use\":" << jsonString(record.whenToUse) << ","
               << "\"source\":" << jsonString(record.source) << ","
               << "\"context\":" << jsonString(record.context) << ","
               << "\"model_invocable\":" << jsonBool(record.modelInvocable)
               << "}";
    }
    output << "],\"listing_reminder\":" << jsonString(formatListing(matches, contextWindowTokens)) << "}";
    return output.str();
}

std::string SkillRegistry::listingReminder(int contextWindowTokens, const std::string &cwd) const {
    return formatListing(visibleRecords(cwd), contextWindowTokens);
}

std::string SkillRegistry::catalogJson(const std::string &cwd) const {
    const std::vector<SkillRecord> visible = visibleRecords(cwd);
    std::ostringstream output;
    output << "[";
    for (size_t index = 0; index < visible.size(); index++) {
        if (index > 0) {
            output << ",";
        }
        output << "{"
               << "\"name\":" << jsonString(visible[index].canonicalName) << ","
               << "\"description\":" << jsonString(visible[index].description) << ","
               << "\"when_to_use\":" << jsonString(visible[index].whenToUse) << ","
               << "\"source\":" << jsonString(visible[index].source) << ","
               << "\"context\":" << jsonString(visible[index].context)
               << "}";
    }
    output << "]";
    return output.str();
}

size_t SkillRegistry::skillCount() const {
    return records_.size();
}

SkillRegistry::SkillRecord SkillRegistry::parseRecord(const std::string &metadataJson) const {
    std::map<std::string, JsonField> fields;
    parseFieldsOrEmpty(metadataJson, fields);
    SkillRecord record;
    record.raw = metadataJson;
    record.canonicalName = stringField(fields, "canonicalName", stringField(fields, "canonical_name", stringField(fields, "name")));
    record.description = stringField(fields, "description");
    record.whenToUse = stringField(fields, "whenToUse", stringField(fields, "when_to_use"));
    record.source = stringField(fields, "source", "host");
    record.directory = stringField(fields, "directory", stringField(fields, "root"));
    record.skillFile = stringField(fields, "skillFile", stringField(fields, "skill_file"));
    record.context = stringField(fields, "context", "inline");
    record.visible = boolField(fields, "visible", true);
    const bool disabled = boolField(fields, "disableModelInvocation", boolField(fields, "disable_model_invocation", false));
    record.modelInvocable = boolField(fields, "modelInvocable", boolField(fields, "model_invocable", !disabled)) && !disabled;
    return record;
}

bool SkillRegistry::visibleFromCwd(const SkillRecord &record, const std::string &cwd) const {
    if (!record.visible || !record.modelInvocable) {
        return false;
    }
    if (record.directory.empty() || cwd.empty()) {
        return true;
    }
    return startsWithPath(cwd, record.directory);
}

bool SkillRegistry::matches(const SkillRecord &record, const std::string &query) const {
    const std::string normalizedQuery = lowercased(trim(query));
    if (normalizedQuery.empty()) {
        return true;
    }
    if (normalizedQuery.rfind("select:", 0) == 0) {
        const std::string selected = lowercased(normalizedQuery.substr(7));
        return lowercased(record.canonicalName) == selected;
    }
    const std::string haystack = lowercased(record.canonicalName + " " + record.description + " " + record.whenToUse + " " + record.source);
    for (const std::string &term : splitTerms(normalizedQuery)) {
        if (haystack.find(term) == std::string::npos) {
            return false;
        }
    }
    return true;
}

std::string SkillRegistry::formatListing(const std::vector<SkillRecord> &records, int contextWindowTokens) const {
    if (records.empty()) {
        return "";
    }
    const std::string header =
        "<system-reminder>\n"
        "The following skills are available through the Skill tool. Invoke a skill only when the task clearly matches its description or when_to_use guidance; do not call skills just to demonstrate capability. Skill context is transient and serves only the current request unless it explicitly writes files or memory.\n\n";
    const std::string footer = "\n</system-reminder>";
    int budgetChars = static_cast<int>(static_cast<double>(contextWindowTokens) * kSkillListingBudgetPct * kCharsPerTokenEstimate);
    const int minimum = static_cast<int>(header.size() + footer.size() + 16);
    if (budgetChars < minimum) {
        budgetChars = minimum;
    }

    std::vector<std::string> entries;
    entries.reserve(records.size());
    for (const SkillRecord &record : records) {
        entries.push_back(formatEntry(record));
    }
    const std::string fullBody = [&entries]() {
        std::ostringstream body;
        for (size_t index = 0; index < entries.size(); index++) {
            if (index > 0) {
                body << "\n";
            }
            body << entries[index];
        }
        return body.str();
    }();
    const std::string fullText = header + fullBody + footer;
    if (static_cast<int>(fullText.size()) <= budgetChars) {
        return fullText;
    }

    int remaining = budgetChars - static_cast<int>(header.size() + footer.size() + 1);
    std::vector<std::string> rendered;
    for (size_t index = 0; index < entries.size(); index++) {
        const std::string &entry = entries[index];
        if (remaining >= static_cast<int>(entry.size() + 1)) {
            rendered.push_back(entry);
            remaining -= static_cast<int>(entry.size() + 1);
            continue;
        }
        const std::string namesOnly = "- " + records[index].canonicalName;
        if (remaining >= static_cast<int>(namesOnly.size() + 1)) {
            rendered.push_back(namesOnly);
            remaining -= static_cast<int>(namesOnly.size() + 1);
        }
    }
    if (rendered.empty()) {
        rendered.push_back("- " + records.front().canonicalName);
    }
    std::ostringstream body;
    for (size_t index = 0; index < rendered.size(); index++) {
        if (index > 0) {
            body << "\n";
        }
        body << rendered[index];
    }
    std::string bodyText = body.str();
    const int bodyLimit = budgetChars - static_cast<int>(header.size() + footer.size());
    if (static_cast<int>(bodyText.size()) > bodyLimit) {
        bodyText = bodyText.substr(0, static_cast<size_t>(std::max(0, bodyLimit)));
    }
    return header + bodyText + footer;
}

std::string SkillRegistry::formatEntry(const SkillRecord &record) const {
    std::string entry = "- " + record.canonicalName + ": " + clipText(record.description, kMaxListingDescriptionCharacters);
    if (!trim(record.whenToUse).empty()) {
        entry += "\n  When to use: " + clipText(record.whenToUse, kMaxListingDescriptionCharacters);
    }
    return entry;
}

std::vector<SkillRegistry::SkillRecord> SkillRegistry::visibleRecords(const std::string &cwd) const {
    std::vector<SkillRecord> visible;
    for (const SkillRecord &record : records_) {
        if (visibleFromCwd(record, cwd)) {
            visible.push_back(record);
        }
    }
    std::sort(visible.begin(), visible.end(), [](const SkillRecord &lhs, const SkillRecord &rhs) {
        const int leftPriority = sourcePriority(lhs.source);
        const int rightPriority = sourcePriority(rhs.source);
        if (leftPriority == rightPriority) {
            return lowercased(lhs.canonicalName) < lowercased(rhs.canonicalName);
        }
        return leftPriority < rightPriority;
    });
    return visible;
}

} // namespace LuminaAgent
