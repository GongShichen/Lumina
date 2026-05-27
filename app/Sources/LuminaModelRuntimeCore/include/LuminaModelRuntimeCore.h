#pragma once

#ifdef __cplusplus
extern "C" {
#endif

char *LuminaMiniCPMV46BackendCapabilities(void);

char *LuminaMiniCPMV46GenerateReActJSON(
    const char *modelDirectory,
    const char *backendPreference,
    const char *prompt,
    int contextLength,
    int maxOutputTokens,
    int safetyMarginTokens
);

void LuminaModelRuntimeFreeCString(char *value);

#ifdef __cplusplus
}
#endif
