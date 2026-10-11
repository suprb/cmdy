// Offscreen Metal and actual shader uniforms; no app/window/input/PTY.
#define CMDY_PUBLICATION_CONTRACT_NAME preceding_publication_contract
#include "PublishedSession.m"
#include <float.h>
#include <math.h>
#include <string.h>

typedef struct ActivityUniforms {
    float resolution[2], time, curvature, background[4], cursor[2];
    float key_age, typing_rate, opacity;
    uint32_t pass_index;
    uint32_t padding[2];
} ActivityUniforms;
static ActivityUniforms observed;
static atomic_uint uniform_count;
void fixture_encoder_bytes_impl(const void *, const void *, size_t, size_t, uint8_t);
void cmdy_gpu_apple_encoder_bytes(const void *encoder, const void *bytes, size_t length,
                                  size_t index, uint8_t fragment) {
    if (fragment && index == 0 && length == sizeof(ActivityUniforms)) {
        memcpy(&observed, bytes, length);
        atomic_fetch_add(&uniform_count, 1);
    }
    fixture_encoder_bytes_impl(encoder, bytes, length, index, fragment);
}
static void activity(SessionTest *t, double keypress, double rate, uint64_t request) {
    CmdyRenderSessionCommand command = {.kind = CMDY_SESSION_INPUT_ACTIVITY,
        .value = keypress, .value2 = rate, .request_id = request};
    // Deliberately obsolete/empty environment must not hide or detach the view.
    assert(cmdy_render_session_post(t->session, &command));
    CmdyRenderSessionUpdate result = matching(t, CMDY_SESSION_ACTIONS, request);
    assert(result.success && result.actions.flags == 0);
    assert(result.environment.has_view && result.environment.has_source && result.environment.visible);
}
static void publish_shader(SessionTest *t, CmdyRenderSessionUpdate capture, LayerFixture *layer) {
    CmdyRenderOwnedFrameInput *original = publication_frame(capture, (CmdyRenderColor){1, 0, 0, 1}, 0);
    CmdyRenderFrameInput metadata = *cmdy_render_frame_input_metadata(original);
    metadata.parameters.shader_mode = 1;
    metadata.parameters.now = 123;
    metadata.parameters.activity_keypress_time = 120.75;
    metadata.parameters.typing_rate = 2.5;
    CmdyRenderOwnedFrameInput *frame = cmdy_render_frame_input_reuse(original, &metadata, NULL);
    assert(frame);
    assert(cmdy_render_session_publish_layer(t->session, frame, capture.source_revision,
        (__bridge const void *)layer, 0, environment(), NULL, NULL, NULL));
    cmdy_render_frame_input_release(frame); cmdy_render_frame_input_release(original);
    assert(matching(t, CMDY_SESSION_FRAME, 0).success); gpu_done(t);
}

int main(void) {
    completed = dispatch_semaphore_create(0); continue_completion = dispatch_semaphore_create(0);
    encoded = dispatch_semaphore_create(0); continue_encode = dispatch_semaphore_create(0);
    feedback_registered = dispatch_semaphore_create(0);
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice(); assert(device);
        SessionTest t; start_layer(&t, device);
        CmdyRenderSessionUpdate first = capture(&t);
        LayerFixture *layer = layer_for(&t, device);
        publish_shader(&t, first, layer);
        assert(atomic_load(&uniform_count) == 1);
        assert(observed.key_age == 2.25f && observed.typing_rate == 2.5f);
        puts("Input activity: frame-provided shader uniforms remain the fallback before the first scalar command PASS");

        unsigned draws = atomic_load(&layer->acquisitions);
        activity(&t, 0, 6.5, 2101);
        assert(cmdy_render_session_source_revision(t.session) == first.source_revision);
        assert(cmdy_render_session_epoch(t.session) == first.identity.epoch);
        assert(atomic_load(&layer->acquisitions) == draws);
        request_publication_draw(&t);
        CmdyRenderSessionUpdate frame = worker_frame(&t);
        assert(frame.source_revision == first.source_revision);
        assert(atomic_load(&uniform_count) == 2);
        assert(observed.key_age == 10 && observed.typing_rate == 6.5f);
        puts("Input activity: telemetry preserves the publication and reaches real shader uniforms without a host capture PASS");

        activity(&t, environment().now + 1000000, 9.25, 2102);
        request_publication_draw(&t); (void)worker_frame(&t);
        assert(observed.key_age == 0 && observed.typing_rate == 9.25f);
        // An old host capture must not replace worker-owned scalar state.
        cmdy_render_session_source_changed(t.session, environment());
        CmdyRenderSessionUpdate fresh = capture(&t);
        publish_shader(&t, fresh, layer);
        assert(observed.key_age == 0 && observed.typing_rate == 9.25f);
        puts("Input activity: newest scalars survive reused frames and an older host capture after UI invalidation PASS");

        const double invalid[][2] = {{NAN, 1}, {INFINITY, 1}, {-1, 1}, {1, NAN}, {1, INFINITY}, {1, -1}, {1, DBL_MAX}};
        for (size_t i = 0; i < sizeof(invalid) / sizeof(invalid[0]); i++) {
            CmdyRenderSessionCommand command = {.kind = CMDY_SESSION_INPUT_ACTIVITY,
                .value = invalid[i][0], .value2 = invalid[i][1]};
            assert(!cmdy_render_session_post(t.session, &command));
        }
        request_publication_draw(&t); (void)worker_frame(&t);
        assert(observed.key_age == 0 && observed.typing_rate == 9.25f);
        cmdy_render_session_close(t.session);
        CmdyRenderSessionCommand closed = {.kind = CMDY_SESSION_INPUT_ACTIVITY, .value = 0, .value2 = 1};
        assert(!cmdy_render_session_post(t.session, &closed));
        cleanup(&t);
        puts("Input activity: invalid and closed-session commands reject without overwriting accepted values PASS");
    }
    return 0;
}
