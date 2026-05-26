#pragma once

#include <string>

namespace LuminaAgent {

// Returns the compact contract embedded in every model-facing task envelope.
std::string contractJson();

// Returns the JSON schema description for semantic task envelopes.
std::string taskEnvelopeSchemaJson();

// Returns the JSON schema description for structured ReAct model steps.
std::string reactStepSchemaJson();

// Returns the JSON schema description for final Markdown responder output.
std::string responderSchemaJson();

// Returns all runtime contracts in one JSON object for tooling/export.
std::string allContractsJson();

} // namespace LuminaAgent
