// Headless Metal correctness. No NSApplication, window, input, PTY or clipboard.
// Keep the existing target/session contract checks in the same executable.
#define main existing_session_contract
#include "RendererSession.m"
#undef main
#import <QuartzCore/QuartzCore.h>

@interface LayerFixture : CAMetalLayer {
@public
    SessionTest *sessionTest;
    atomic_uint acquisitions;
    atomic_bool blockNext, missingNext;
    dispatch_semaphore_t entered, resume;
    id<MTLTexture> lastTexture;
}
@end
@implementation LayerFixture
- (id<CAMetalDrawable>)nextDrawable {
    assert(!NSThread.isMainThread);
    assert(sessionTest->has_owner && pthread_equal(sessionTest->owner, pthread_self()));
    atomic_fetch_add(&acquisitions, 1);
    if (atomic_exchange(&blockNext, false)) {
        dispatch_semaphore_signal(entered);
        wait_for(resume);
    }
    if (atomic_exchange(&missingNext, false)) return nil;
    id<CAMetalDrawable> value = [super nextDrawable];
    assert(value && value.texture);
    lastTexture = value.texture;
    return value;
}
@end

typedef struct LayerObservation {
    atomic_uint callbacks, releases;
    dispatch_semaphore_t released;
    CmdyRenderFrameIdentity identity;
} LayerObservation;
static LayerObservation observation(CmdyRenderFrameIdentity identity) {
    return (LayerObservation){.released = dispatch_semaphore_create(0), .identity = identity};
}
static void layer_presented(void *context, const CmdyRenderLayerPresentation *value) {
    LayerObservation *o = context;
    assert(value && value->identity.surface == o->identity.surface);
    assert(value->identity.epoch == o->identity.epoch && value->identity.sequence == o->identity.sequence);
    assert(value->pixel_width == 8 && value->pixel_height == 8 && value->presented_time >= 0);
    assert(atomic_fetch_add(&o->callbacks, 1) == 0);
}
static void layer_released(void *context) {
    LayerObservation *o = context;
    assert(atomic_fetch_add(&o->releases, 1) == 0);
    dispatch_semaphore_signal(o->released);
}
static LayerFixture *layer_for(SessionTest *t, id<MTLDevice> device) {
    LayerFixture *layer = [LayerFixture new];
    layer->sessionTest = t;
    layer->entered = dispatch_semaphore_create(0);
    layer->resume = dispatch_semaphore_create(0);
    layer.device = device;
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.framebufferOnly = NO;
    layer.frame = CGRectMake(0, 0, 8, 8);
    layer.drawableSize = CGSizeMake(8, 8);
    layer.allowsNextDrawableTimeout = YES;
    layer.presentsWithTransaction = NO;
    layer.displaySyncEnabled = NO;
    return layer;
}
static bool layer_submit(SessionTest *t, CmdyRenderFrameIdentity identity, CAMetalLayer *layer,
                         LayerObservation *o, CmdyRenderColor color) {
    CmdyRenderFrameInput input = {.identity = identity};
    input.parameters = (CmdyGpuFrame){.width = 8, .height = 8, .scale = 1, .cell_width = 8,
        .cell_height = 8, .grid_rows = 1, .grid_cols = 1, .cursor_hidden = 1,
        .image_scale = 1, .background = color, .now = environment().now};
    uint32_t status = 99;
    CmdyRenderOwnedFrameInput *frame = cmdy_render_frame_input_capture(&input, &status);
    assert(frame && status == CMDY_RENDER_INPUT_OK);
    bool result = cmdy_render_session_submit_layer(t->session, frame, (__bridge const void *)layer,
        0, environment(), o ? layer_presented : NULL, o, o ? layer_released : NULL);
    cmdy_render_frame_input_release(frame);
    return result;
}
static void layer_pixels(id<MTLDevice> device, id<MTLTexture> texture, uint8_t r, uint8_t g, uint8_t b) {
    // Layer textures may be private; use a real blit after GPU completion.
    id<MTLBuffer> bytes = [device newBufferWithLength:8 * 256 options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> queue = [device newCommandQueue];
    id<MTLCommandBuffer> buffer = [queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [buffer blitCommandEncoder];
    [blit copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
              sourceSize:MTLSizeMake(8, 8, 1) toBuffer:bytes destinationOffset:0
              destinationBytesPerRow:256 destinationBytesPerImage:8 * 256];
    [blit endEncoding]; [buffer commit]; [buffer waitUntilCompleted];
    assert(buffer.status == MTLCommandBufferStatusCompleted);
    const uint8_t *data = bytes.contents;
    for (unsigned y = 0; y < 8; y++) for (unsigned x = 0; x < 8; x++) {
        const uint8_t *p = data + y * 256 + x * 4;
        assert(p[0] == b && p[1] == g && p[2] == r && p[3] == 255);
    }
}
static CmdyRenderSessionUpdate inspect_layer(SessionTest *t) {
    post(t, CMDY_SESSION_INSPECT, 0, 701);
    return matching(t, CMDY_SESSION_INSPECTION, 701);
}
static void start_layer(SessionTest *t, id<MTLDevice> device) {
    setup(t, device);
    assert(matching(t, CMDY_SESSION_READY, 0).success);
}

#ifndef CMDY_LAYER_CONTRACT_NAME
#define CMDY_LAYER_CONTRACT_NAME main
#endif
int CMDY_LAYER_CONTRACT_NAME(void) {
    assert(existing_session_contract() == 0);
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice(); assert(device);
        SessionTest t;
        start_layer(&t, device);
        CmdyRenderSessionUpdate requested = capture(&t);
        LayerObservation o = observation(requested.identity);
        @autoreleasepool {
            LayerFixture *layer = layer_for(&t, device);
            assert(layer_submit(&t, requested.identity, layer, &o, (CmdyRenderColor){1, 0, 0, 1}));
            assert(matching(&t, CMDY_SESSION_FRAME, 0).success);
            gpu_done(&t);
            assert(atomic_load(&layer->acquisitions) == 1);
            layer_pixels(device, layer->lastTexture, 255, 0, 0);
            cleanup(&t);
            layer->lastTexture = nil;
        }
        wait_for(o.released);
        assert(atomic_load(&o.releases) == 1);
        puts("Layer session: actual worker nextDrawable, retained frame/target, real Metal pixels and independent observer disposal PASS");

        start_layer(&t, device); requested = capture(&t); o = observation(requested.identity);
        LayerFixture *layer = layer_for(&t, device);
        atomic_store(&layer->missingNext, true);
        assert(layer_submit(&t, requested.identity, layer, &o, (CmdyRenderColor){0, 1, 0, 1}));
        CmdyRenderSessionUpdate state = inspect_layer(&t);
        assert(!state.inspection.drawing && !state.inspection.frame_in_flight);
        assert(atomic_load(&layer->acquisitions) == 1 && atomic_load(&o.releases) == 1 && atomic_load(&o.callbacks) == 0);
        cleanup(&t);
        puts("Layer session: missing drawable finishes capture and disposes context without a committed frame PASS");

        start_layer(&t, device); requested = capture(&t); o = observation(requested.identity);
        layer = layer_for(&t, device); layer.drawableSize = CGSizeMake(16, 8);
        uint64_t frames = cmdy_gpu_counter(0);
        assert(layer_submit(&t, requested.identity, layer, &o, (CmdyRenderColor){0, 1, 0, 1}));
        state = inspect_layer(&t);
        assert(!state.inspection.drawing && !state.inspection.frame_in_flight);
        assert(cmdy_gpu_counter(0) == frames && atomic_load(&o.releases) == 1);
        cleanup(&t);
        puts("Layer session: actual drawable dimensions reject stale geometry before GPU commit PASS");

        start_layer(&t, device); requested = capture(&t); o = observation(requested.identity);
        layer = layer_for(&t, device);
        post(&t, CMDY_SESSION_EVENT, CMDY_RENDER_RESET_PACING, 98); wait_for(t.blocked);
        assert(layer_submit(&t, requested.identity, layer, &o, (CmdyRenderColor){0, 0, 1, 1}));
        assert(cmdy_render_session_invalidate(t.session, environment()) == requested.identity.epoch + 1);
        dispatch_semaphore_signal(t.unblock);
        state = inspect_layer(&t);
        assert(!state.inspection.drawing && atomic_load(&layer->acquisitions) == 0 && atomic_load(&o.releases) == 1);
        cleanup(&t);
        puts("Layer session: queued stale epoch disposes inputs without acquiring any drawable PASS");

        start_layer(&t, device); requested = capture(&t); o = observation(requested.identity);
        layer = layer_for(&t, device); atomic_store(&layer->blockNext, true);
        assert(layer_submit(&t, requested.identity, layer, &o, (CmdyRenderColor){0, 0, 1, 1}));
        wait_for(layer->entered); frames = cmdy_gpu_counter(0);
        // These calls must return while nextDrawable is still blocked.
        assert(cmdy_render_session_invalidate(t.session, environment()) == requested.identity.epoch + 1);
        assert(atomic_load(&o.releases) == 0);
        dispatch_semaphore_signal(layer->resume);
        state = inspect_layer(&t);
        assert(!state.inspection.drawing && cmdy_gpu_counter(0) == frames && atomic_load(&o.releases) == 1);
        cleanup(&t);
        puts("Layer session: resize proceeds during acquisition and cancels the returned obsolete drawable PASS");

        start_layer(&t, device); requested = capture(&t); o = observation(requested.identity);
        layer = layer_for(&t, device); atomic_store(&layer->blockNext, true);
        assert(layer_submit(&t, requested.identity, layer, &o, (CmdyRenderColor){0, 0, 1, 1}));
        wait_for(layer->entered); frames = cmdy_gpu_counter(0);
        cmdy_render_session_close(t.session); assert(cmdy_render_session_epoch(t.session) == 0);
        assert(atomic_load(&o.releases) == 0);
        dispatch_semaphore_signal(layer->resume); cleanup(&t);
        assert(cmdy_gpu_counter(0) == frames && atomic_load(&o.releases) == 1);
        puts("Layer session: close returns during acquisition; drain releases context and prevents commit PASS");

        start_layer(&t, device); requested = capture(&t); o = observation(requested.identity);
        layer = layer_for(&t, device); layer.allowsNextDrawableTimeout = NO;
        assert(!layer_submit(&t, requested.identity, layer, &o, (CmdyRenderColor){0, 0, 1, 1}));
        assert(atomic_load(&o.releases) == 0 && atomic_load(&layer->acquisitions) == 0);
        layer.allowsNextDrawableTimeout = YES; layer.presentsWithTransaction = YES;
        assert(!layer_submit(&t, requested.identity, layer, &o, (CmdyRenderColor){0, 0, 1, 1}));
        assert(atomic_load(&o.releases) == 0);
        layer.presentsWithTransaction = NO;
        CmdyRenderFrameIdentity wrong = requested.identity; wrong.surface++;
        assert(!layer_submit(&t, wrong, layer, &o, (CmdyRenderColor){0, 0, 1, 1}));
        assert(atomic_load(&o.releases) == 0);
        layer_released(&o); cleanup(&t);
        puts("Layer session: unsafe layer settings and wrong surface reject without taking caller context PASS");
    }
    return 0;
}
