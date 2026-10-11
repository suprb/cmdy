#ifndef CMDY_TEST_OBSERVED_SESSION_FACTORY_H
#define CMDY_TEST_OBSERVED_SESSION_FACTORY_H
#include "cmdy_render_session.h"
#include <assert.h>
#include <stdbool.h>
#include <stdlib.h>

// Existing contracts own their callback stream. Consume only our private
// initialization command's reply before forwarding every production update.
typedef struct ObservedSessionRelay {
    CmdyRenderSessionCallback callback;
    CmdyRenderWorkerCallback dispose;
    void *context;
} ObservedSessionRelay;
static void observed_session_callback(void *context, const CmdyRenderSessionUpdate *value) {
    ObservedSessionRelay *relay = context;
    if (value->request_id == UINT64_MAX) {
        assert(value->kind == CMDY_SESSION_ACTIONS && value->success);
        return;
    }
    relay->callback(relay->context, value);
}
static void observed_session_dispose(void *context) {
    ObservedSessionRelay *relay = context;
    if (relay->dispose) relay->dispose(relay->context);
    free(relay);
}
static CmdyRenderSession *create_observed_session(const void *device, uint64_t format,
    size_t samples, uint64_t surface, double now, uint32_t options,
    CmdyRenderSessionCallback callback, void *context, CmdyRenderWorkerCallback dispose) {
    ObservedSessionRelay *relay = malloc(sizeof(*relay)); assert(relay);
    *relay = (ObservedSessionRelay){callback, dispose, context};
    CmdyRenderSession *session = cmdy_render_session_create_with_options(device, format,
        samples, surface, now, options, callback ? observed_session_callback : NULL,
        relay, observed_session_dispose);
    if (!session) { free(relay); return NULL; }
    CmdyRenderSessionCommand command = {.kind = CMDY_SESSION_OBSERVE_FRAMES,
        .event = 1, .request_id = UINT64_MAX};
    assert(cmdy_render_session_post(session, &command));
    return session;
}
#endif
