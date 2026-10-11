// Headless C ABI integration: no app, window, input, PTY or timing comparison.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "cmdy_render_session.h"
#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>

typedef struct {
    CmdyRenderSession *session;
    dispatch_semaphore_t ready, resume, available, replied;
    pthread_t owner;
    size_t replies, notices, expectedReplies;
    atomic_uint disposed;
} CapacityTest;

static void wait_for(dispatch_semaphore_t semaphore) {
    assert(dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) == 0);
}
static void update(void *context, const CmdyRenderSessionUpdate *value) {
    CapacityTest *t = context;
    assert(!NSThread.isMainThread);
    if (value->kind == CMDY_SESSION_READY) {
        assert(value->success);
        t->owner = pthread_self();
        dispatch_semaphore_signal(t->ready);
        wait_for(t->resume);
        return;
    }
    assert(pthread_equal(t->owner, pthread_self()));
    assert(value->kind != CMDY_SESSION_ERROR);
    if (value->kind == CMDY_SESSION_INSPECTION) {
        assert(value->request_id == t->replies + 1);
        t->replies++;
        if (t->replies == t->expectedReplies) dispatch_semaphore_signal(t->replied);
    } else if (value->kind == CMDY_SESSION_CAPACITY_AVAILABLE) {
        assert(value->success && value->request_id == 0);
        assert(value->source_revision == cmdy_render_session_source_revision(t->session));
        assert(!cmdy_render_session_wait_for_capacity(t->session));
        t->notices++;
        dispatch_semaphore_signal(t->available);
    }
}
static void dispose(void *context) { atomic_fetch_add(&((CapacityTest *)context)->disposed, 1); }
static void start(CapacityTest *t, id<MTLDevice> device) {
    *t = (CapacityTest){.ready = dispatch_semaphore_create(0), .resume = dispatch_semaphore_create(0),
        .available = dispatch_semaphore_create(0), .replied = dispatch_semaphore_create(0)};
    t->session = cmdy_render_session_create((__bridge const void *)device, MTLPixelFormatBGRA8Unorm,
        1, 91, NSProcessInfo.processInfo.systemUptime, update, t, dispose);
    assert(t->session);
    wait_for(t->ready);
}
static size_t fill(CapacityTest *t) {
    size_t accepted = 0;
    CmdyRenderSessionCommand command = {.kind = CMDY_SESSION_INSPECT};
    for (size_t i = 1; i <= 2048; i++) {
        command.request_id = i;
        if (!cmdy_render_session_post(t->session, &command)) break;
        accepted++;
    }
    // Initialization plus the session and GPU close tickets occupy three slots.
    assert(accepted == 1021);
    return accepted;
}
static void finish(CapacityTest *t) {
    assert(cmdy_render_session_destroy(t->session));
    assert(atomic_load(&t->disposed) == 1);
}
int main(void) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice(); assert(device);
        CapacityTest t;
        start(&t, device);
        size_t accepted = fill(&t);
        t.expectedReplies = accepted + 1;
        assert(cmdy_render_session_wait_for_capacity(t.session));
        assert(cmdy_render_session_wait_for_capacity(t.session));
        CmdyRenderScheduleEnvironment environment = {.now = NSProcessInfo.processInfo.systemUptime};
        assert(cmdy_render_session_source_changed(t.session, environment) == 2);
        dispatch_semaphore_signal(t.resume);
        wait_for(t.available);
        assert(t.replies == accepted && t.notices == 1);
        CmdyRenderSessionCommand retry = {.kind = CMDY_SESSION_INSPECT, .request_id = accepted + 1};
        assert(cmdy_render_session_post(t.session, &retry));
        wait_for(t.replied);
        finish(&t);
        assert(t.replies == accepted + 1 && t.notices == 1);
        puts("Session capacity: saturated FIFO resumes once across source invalidation PASS");

        start(&t, device);
        accepted = fill(&t);
        t.expectedReplies = accepted;
        dispatch_semaphore_signal(t.resume);
        wait_for(t.replied);
        assert(!cmdy_render_session_wait_for_capacity(t.session));
        finish(&t);
        assert(t.replies == accepted && t.notices == 0);
        puts("Session capacity: drained queue requests immediate retry without notification PASS");

        start(&t, device);
        (void)fill(&t);
        assert(cmdy_render_session_wait_for_capacity(t.session));
        cmdy_render_session_close(t.session);
        assert(!cmdy_render_session_wait_for_capacity(t.session));
        dispatch_semaphore_signal(t.resume);
        finish(&t);
        assert(t.replies == 0 && t.notices == 0);
        puts("Session capacity: close cancels waiting notification and drains ownership PASS");
    }
    return 0;
}
