#pragma once
#include <stdbool.h>

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

// The callback/context are scoped to this synchronous request and never retained.
typedef bool (*LuminaModelCancellationCallback)(void *context);
char *LuminaMiniCPMV46GenerateReActJSONCancellable(
    const char *modelDirectory,
    const char *backendPreference,
    const char *prompt,
    int contextLength,
    int maxOutputTokens,
    int safetyMarginTokens,
    LuminaModelCancellationCallback isCancelled,
    void *cancellationContext
);

void LuminaModelRuntimeFreeCString(char *value);

#ifdef __cplusplus
}
#endif
