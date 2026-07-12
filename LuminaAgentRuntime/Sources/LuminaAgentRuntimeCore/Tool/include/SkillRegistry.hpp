#pragma once

#include <string>
#include <vector>

#include "Json.hpp"

namespace LuminaAgent {

class SkillRegistry {
public:
    std::string registerMetadata(const char *skillMetadataJson);
    std::string discoverSkillsJson(const std::string &query, int maxResults, int contextWindowTokens, const std::string &cwd) const;
    std::string listingReminder(int contextWindowTokens, const std::string &cwd) const;
    std::string catalogJson(const std::string &cwd = "") const;
    size_t skillCount() const;

private:
    struct SkillRecord {
        std::string raw;
        std::string canonicalName;
        std::string description;
        std::string whenToUse;
        std::string source;
        std::string directory;
        std::string skillFile;
        std::string context;
        bool visible = true;
        bool modelInvocable = true;
    };

    SkillRecord parseRecord(const std::string &metadataJson) const;
    bool visibleFromCwd(const SkillRecord &record, const std::string &cwd) const;
    bool matches(const SkillRecord &record, const std::string &query) const;
    std::string formatListing(const std::vector<SkillRecord> &records, int contextWindowTokens) const;
    std::string formatEntry(const SkillRecord &record) const;
    std::vector<SkillRecord> visibleRecords(const std::string &cwd) const;

    std::vector<SkillRecord> records_;
};

} // namespace LuminaAgent
