// Used by NativeEngineBridgeCancellationTests; exercises both external ABIs.
#include <stdbool.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static atomic_bool started = false;
static atomic_bool released = false;
int LuminaFakeEngineStarted(void) { return atomic_load(&started); }
void LuminaFakeEngineRelease(void) { atomic_store(&released, true); }

static char *generate(bool (*cancelled)(void *), void *context) {
    atomic_store(&started, true);
    const struct timespec tick = {0, 1000000};
    for (int i = 0; i < 5000 && !atomic_load(&released); ++i) {
        if (cancelled != NULL && cancelled(context)) {
            return strdup("{\"ok\":false,\"error\":\"cancelled by request callback\",\"backend\":\"cpu\"}");
        }
        nanosleep(&tick, NULL);
    }
    return strdup("{\"ok\":true,\"output\":\"completed\",\"backend\":\"cpu\"}");
}

char *LuminaMiniCPMV46ExternalGenerateReActJSON(const char *model, const char *backend,
    const char *prompt, int context, int maximum, int margin) {
    return generate(NULL, NULL);
}

#if LUMINA_FAKE_CANCELLABLE
char *LuminaMiniCPMV46ExternalGenerateReActJSONCancellable(const char *model, const char *backend,
    const char *prompt, int context, int maximum, int margin,
    bool (*cancelled)(void *), void *state) {
    return generate(cancelled, state);
}
#endif
