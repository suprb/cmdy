// Headless correctness only: no NSApplication, windows, PTY, input or clipboard.
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#include "cmdy_render_gpu.h"
#include "platform_gpu.h"
#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>

static _Thread_local unsigned scope_depth;
static atomic_uint scope_count;
static void pool(CmdyRenderWorkerCallback body, void *context) {
    @autoreleasepool { scope_depth++; atomic_fetch_add(&scope_count, 1); body(context); scope_depth--; }
}
typedef struct Test {
    CmdyRenderWorker *worker;
    CmdyRenderGPU *gpu;
    const void *device, *texture, *pass, *image, *image_owner;
    CmdyGpuFrame frame;
    CmdyGpuFrameRow row;
    pthread_t owner_thread;
    dispatch_semaphore_t frames_done, image_done;
    unsigned frames, images, cancellations;
    bool stopped, expect_image;
} Test;
static void owner(Test *t) {
    assert(scope_depth == 1 && ![NSThread isMainThread]);
    assert(pthread_equal(t->owner_thread, pthread_self()));
}
static void wait_for(dispatch_semaphore_t signal) {
    assert(dispatch_semaphore_wait(signal, dispatch_time(DISPATCH_TIME_NOW, 45 * NSEC_PER_SEC)) == 0);
}
typedef struct Call { Test *test; void (*fn)(Test *); dispatch_semaphore_t done; } Call;
static void run(void *context, CmdyRenderWorker *worker, uint64_t epoch) {
    Call *call = context; assert(worker == call->test->worker && epoch != 0);
    call->fn(call->test);
}
static void dispose(void *context, uint32_t reason) {
    Call *call = context; assert(reason == CMDY_RENDER_WORKER_EXECUTED);
    dispatch_semaphore_signal(call->done);
}
static void invoke(Test *t, void (*fn)(Test *)) {
    Call call = {.test = t, .fn = fn, .done = dispatch_semaphore_create(0)};
    assert(cmdy_render_worker_submit(t->worker, cmdy_render_worker_epoch(t->worker), &call, run, dispose));
    wait_for(call.done);
}
static void check_pixels(Test *t, const void *raw, bool ordinary) {
    owner(t);
    id<MTLDevice> device = (__bridge id)t->device;
    id<MTLTexture> texture = (__bridge id)raw;
    assert(texture.width >= 2 && texture.height >= 1);
    id<MTLBuffer> result = [device newBufferWithLength:256 options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> queue = [device newCommandQueue];
    id<MTLCommandBuffer> buffer = [queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [buffer blitCommandEncoder];
    [blit copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
        sourceSize:MTLSizeMake(2, 1, 1) toBuffer:result destinationOffset:0
        destinationBytesPerRow:256 destinationBytesPerImage:256];
    [blit endEncoding]; [buffer commit]; [buffer waitUntilCompleted];
    assert(buffer.status == MTLCommandBufferStatusCompleted);
    const uint8_t *p = result.contents;
    bool bgra = texture.pixelFormat == MTLPixelFormatBGRA8Unorm;
    assert(bgra || texture.pixelFormat == MTLPixelFormatRGBA8Unorm);
    assert(p[bgra ? 2 : 0] == 255 && p[1] == 0 && p[bgra ? 0 : 2] == 0 && p[3] == 255);
    if (ordinary) assert(p[4] == 0 && p[5] == 255 && p[6] == 0 && p[7] == 255);
    else assert(p[bgra ? 6 : 4] == 255 && p[5] == 0 && p[bgra ? 4 : 6] == 0 && p[7] == 255);
}
static void event(void *context, uint32_t kind) {
    Test *t = context; owner(t);
    if (kind == 1) {
        check_pixels(t, t->texture, false);
        t->frames++;
        if (t->frames == 1) {
            // Completion clears native in-flight state before reentrant draw.
            assert(cmdy_gpu_draw(t->gpu, &t->frame));
        } else { assert(t->frames == 2); dispatch_semaphore_signal(t->frames_done); }
    } else if (kind == 2) {
        assert(t->expect_image && t->stopped && cmdy_render_worker_epoch(t->worker) == 0);
        assert(cmdy_gpu_image_pending(t->gpu) == 0 && cmdy_gpu_image_attempts(t->gpu) == 1);
        const void *texture = cmdy_gpu_image_texture(t->gpu, t->image_owner, t->image);
        assert(texture); check_pixels(t, texture, true);
        t->images++; dispatch_semaphore_signal(t->image_done);
    } else assert(false);
}
static void initialize(Test *t) {
    t->owner_thread = pthread_self(); owner(t);
    char error[4096] = {0};
    t->gpu = cmdy_gpu_create_on_worker(t->worker, t->device, MTLPixelFormatBGRA8Unorm, 1, 1, error, sizeof(error));
    if (!t->gpu) fprintf(stderr, "create: %s\n", error);
    assert(t->gpu && cmdy_zig_gpu_schedule(t->gpu));
    cmdy_gpu_set_event(t->gpu, event, t);
    t->texture = cmdy_gpu_apple_texture(t->device, 8, 8, 0, MTLPixelFormatBGRA8Unorm, 1, 0);
    t->pass = cmdy_gpu_apple_pass(t->texture); assert(t->texture && t->pass);
    CmdyRenderSolid background = {.rect = {0, 0, 8, 8}, .color = {1, 0, 0, 1}};
    CmdyGpuRowView view = {.backgrounds = &background, .background_count = 1, .width = 8, .height = 8};
    CmdyGpuRowKey key = {.absolute_row = 0, .version = 1, .cols = 1, .width = 8, .height = 8, .font_name = "headless"};
    t->row.entry = cmdy_gpu_row_import(t->gpu, &key, &view); assert(t->row.entry);
    background.color = (CmdyRenderColor){0, 1, 0, 1}; // Row owns its copied inputs.
    assert(cmdy_gpu_rows_count(t->gpu) == 1);
    t->frame = (CmdyGpuFrame){.pass = t->pass, .rows = &t->row, .row_count = 1,
        .width = 8, .height = 8, .scale = 1, .cell_width = 8, .cell_height = 8,
        .grid_rows = 1, .grid_cols = 1, .cursor_hidden = 1, .image_scale = 1,
        .background = {0, 0, 1, 1}, .now = 1};
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:2 pixelsHigh:1
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace
        bytesPerRow:8 bitsPerPixel:32]; assert(rep);
    const uint8_t pixels[8] = {255, 0, 0, 255, 0, 255, 0, 255}; memcpy(rep.bitmapData, pixels, sizeof(pixels));
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(2, 1)]; [image addRepresentation:rep];
    t->image = (__bridge_retained const void *)image;
    t->image_owner = (__bridge_retained const void *)[NSObject new];
}
static void invalid_draw(Test *t) {
    owner(t); CmdyGpuFrame invalid = t->frame; invalid.width = 0;
    assert(!cmdy_gpu_draw(t->gpu, &invalid)); // Unlaunched work rolls back now.
    assert(cmdy_render_worker_outstanding_completions(t->worker) == 1); // Only close remains.
    assert(t->frames == 0);
}
static void start_frames(Test *t) { owner(t); assert(cmdy_gpu_draw(t->gpu, &t->frame)); }
static void cancelled(void *context, CmdyRenderWorker *worker, uint32_t result) {
    Test *t = context; owner(t); assert(worker == t->worker && result == CMDY_RENDER_COMPLETION_CANCELLED);
    t->cancellations++;
}
static void no_dispose(void *context) { owner(context); }
static void capacity(Test *t) {
    owner(t); CmdyRenderCompletion *tickets[1024]; size_t count = 0;
    while (count < 1024 && (tickets[count] = cmdy_render_worker_prepare_completion(t->worker, t, cancelled, no_dispose))) count++;
    assert(count == 1023); // The renderer's close ticket protects its idle lifetime.
    assert(cmdy_render_worker_outstanding_completions(t->worker) == 1024);
    assert(!cmdy_gpu_draw(t->gpu, &t->frame));
    assert(cmdy_gpu_image_texture(t->gpu, t->image_owner, t->image) == NULL);
    assert(cmdy_gpu_image_pending(t->gpu) == 0 && cmdy_gpu_image_attempts(t->gpu) == 0);
    for (size_t i = 0; i < count; i++) cmdy_render_worker_cancel_completion(tickets[i]);
}
static void start_image_and_stop(Test *t) {
    owner(t); assert(t->cancellations == 1023); t->expect_image = true;
    assert(cmdy_gpu_image_texture(t->gpu, t->image_owner, t->image) == NULL);
    assert(cmdy_gpu_image_pending(t->gpu) == 1 && cmdy_gpu_image_attempts(t->gpu) == 1);
    t->stopped = true; cmdy_render_worker_stop(t->worker);
    // The pending image callback must still run without the main dispatch queue.
}
static void capacity_drained(Test *t) { owner(t); assert(t->cancellations == 1023); }
static void release_targets(Test *t) {
    cmdy_gpu_apple_release(t->image); t->image = NULL;
    cmdy_gpu_apple_release(t->image_owner); t->image_owner = NULL;
    cmdy_gpu_apple_release(t->pass); t->pass = NULL;
    cmdy_gpu_apple_release(t->texture); t->texture = NULL;
}
static void close_with_pending_work(Test *t) {
    owner(t);
    assert(cmdy_gpu_image_texture(t->gpu, t->image_owner, t->image) == NULL);
    assert(cmdy_gpu_image_pending(t->gpu) == 1);
    assert(cmdy_gpu_draw(t->gpu, &t->frame));
    cmdy_gpu_destroy(t->gpu); t->gpu = NULL;
    release_targets(t);
    t->stopped = true; cmdy_render_worker_stop(t->worker);
    // Both accepted jobs finish after close; neither may emit an event.
}
static void close_after_stopped_image(void *context, CmdyRenderWorker *worker, uint32_t result) {
    Test *t = context; owner(t); assert(worker == t->worker && result == CMDY_RENDER_COMPLETION_READY);
    release_targets(t);
}
int main(void) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice(); assert(device);
        Test first = {.device = (__bridge const void *)device, .frames_done = dispatch_semaphore_create(0), .image_done = dispatch_semaphore_create(0)};
        Test second = {.device = (__bridge const void *)device, .frames_done = dispatch_semaphore_create(0), .image_done = dispatch_semaphore_create(0)};
        first.worker = cmdy_render_worker_create_with_scope(pool);
        second.worker = cmdy_render_worker_create_with_scope(pool); assert(first.worker && second.worker);
        char error[4096] = {0};
        assert(!cmdy_gpu_create_on_worker(first.worker, first.device, MTLPixelFormatBGRA8Unorm, 1, 1, error, sizeof(error)));
        cmdy_gpu_counter_set(0, 0); cmdy_gpu_shared_reset();
        size_t constructions = cmdy_gpu_shared_constructions();
        invoke(&first, initialize); invoke(&second, initialize);
        assert(cmdy_gpu_shared_constructions() == constructions + 1);
        // Public operations must reject access from the host to an owned GPU.
        assert(cmdy_zig_gpu_schedule(first.gpu) == NULL && cmdy_gpu_rows_count(first.gpu) == 0);
        assert(!cmdy_gpu_draw(first.gpu, &first.frame)); cmdy_gpu_rows_clear(first.gpu);
        const void *identity = cmdy_gpu_shared_identity(first.device, MTLPixelFormatBGRA8Unorm, 1, error, sizeof(error)); assert(identity);
        cmdy_gpu_shared_reset(); // Existing renderers retain every pipeline/queue.
        const void *replacement = cmdy_gpu_shared_queue(first.device, MTLPixelFormatBGRA8Unorm, 1, error, sizeof(error));
        assert(replacement && replacement != identity);
        id<MTLCommandBuffer> held = [(__bridge id<MTLCommandQueue>)identity commandBuffer];
        [held commit]; [held waitUntilCompleted]; assert(held.status == MTLCommandBufferStatusCompleted);
        cmdy_gpu_apple_release(identity); cmdy_gpu_apple_release(replacement);
        invoke(&first, invalid_draw); invoke(&second, invalid_draw);
        invoke(&first, start_frames); invoke(&second, start_frames);
        wait_for(first.frames_done); wait_for(second.frames_done);
        assert(cmdy_gpu_counter(0) == 4);
        invoke(&first, capacity);
        invoke(&first, capacity_drained);
        // Reserve target cleanup before stop, which rejects new reservations.
        CmdyRenderCompletion *cleanup = cmdy_render_worker_prepare_completion(first.worker, &first, close_after_stopped_image, no_dispose); assert(cleanup);
        invoke(&first, start_image_and_stop); wait_for(first.image_done);
        cmdy_gpu_destroy(first.gpu); first.gpu = NULL; // Cross-thread close after stop.
        cmdy_render_worker_complete(cleanup);
        assert(cmdy_render_worker_destroy(first.worker));
        invoke(&second, close_with_pending_work);
        assert(cmdy_render_worker_destroy(second.worker));
        assert(first.frames == 2 && first.images == 1 && second.frames == 2 && second.images == 0);
        assert(cmdy_gpu_counter(0) == 4 && scope_depth == 0 && atomic_load(&scope_count) > 1023);
        cmdy_gpu_shared_reset();
        puts("GPU worker ownership: pixels, reentry, shared reset, capacity retry, stop and close drain PASS");
    }
    return 0;
}
