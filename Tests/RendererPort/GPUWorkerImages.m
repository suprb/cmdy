// Reuse the headless fixture; execute only the additional cases below.
#define main gpu_owner_predecessor_main
#include "GPUWorkerOwnership.m"
#undef main

typedef struct Images {
    Test core;
    CmdyGpuKittyImage input;
    CmdyGpuKittyPlacement placement;
    uint32_t live;
    const void *png;
    unsigned phase;
    bool decoded, first_draw_done;
    dispatch_semaphore_t ready, begin, phase_done;
} Images;
static void pixel(Images *t, bool red) {
    owner(&t->core); uint8_t p[4];
    id<MTLTexture> texture = (__bridge id)t->core.texture;
    assert(texture.storageMode == MTLStorageModeShared && texture.pixelFormat == MTLPixelFormatBGRA8Unorm);
    [texture getBytes:p bytesPerRow:4 fromRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0];
    assert(p[0] == (red ? 0 : 255) && p[1] == 0 && p[2] == (red ? 255 : 0) && p[3] == 255);
}
static void finish_images(Images *t) {
    cmdy_gpu_destroy(t->core.gpu); t->core.gpu = NULL;
    release_targets(&t->core); cmdy_gpu_apple_release(t->png); t->png = NULL;
    cmdy_render_worker_stop(t->core.worker);
    dispatch_semaphore_signal(t->phase_done);
}
static void image_event(void *context, uint32_t kind) {
    Images *t = context; owner(&t->core);
    if (kind == 2) {
        assert(t->input.kind == 0 && t->phase == 2 && !t->decoded);
        t->decoded = true;
    } else {
        assert(kind == 1);
        if (t->phase == 1) { pixel(t, false); dispatch_semaphore_signal(t->phase_done); return; }
        if (t->phase == 3 || t->input.kind == 1) { pixel(t, true); finish_images(t); return; }
        assert(t->phase == 2 && !t->first_draw_done);
        t->first_draw_done = true;
    }
    if (t->decoded && t->first_draw_done) {
        t->phase = 3;
        assert(cmdy_gpu_draw(t->core.gpu, &t->core.frame));
    }
}
static const uint8_t rgba[] = {255, 0, 0, 255};
static void initialize_images(Test *core) {
    Images *t = (Images *)core;
    dispatch_semaphore_signal(t->ready); wait_for(t->begin);
    initialize(core); cmdy_gpu_set_event(core->gpu, image_event, t);
    CmdyGpuPlaceholder placeholder = {.image_id = 7, .placement_id = 9};
    CmdyGpuRowView view = {.placeholders = &placeholder, .placeholder_count = 1, .width = 8, .height = 8};
    CmdyGpuRowKey key = {.absolute_row = 0, .version = 2, .cols = 1, .width = 8, .height = 8, .font_name = "headless-images"};
    core->row.entry = cmdy_gpu_row_import(core->gpu, &key, &view); assert(core->row.entry);
    t->placement = (CmdyGpuKittyPlacement){.image_id = 7, .placement_id = 9, .cols = 1, .rows = 1};
    t->input.image_id = 7; t->input.width = 1; t->input.height = 1;
    if (t->input.kind == 0) {
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:1 pixelsHigh:1
            bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:4 bitsPerPixel:32];
        assert(rep); memcpy(rep.bitmapData, rgba, sizeof(rgba));
        NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}]; assert(png.length);
        t->png = (__bridge_retained const void *)png; t->input.bytes = png.bytes; t->input.byte_count = png.length;
    } else { t->input.bytes = rgba; t->input.byte_count = sizeof(rgba); }
    t->live = 7;
    core->frame.kitty_images = &t->input; core->frame.kitty_image_count = 1;
    core->frame.kitty_placements = &t->placement; core->frame.kitty_placement_count = 1;
    core->frame.live_kitty_ids = &t->live; core->frame.live_kitty_count = 1;
}
static void limited_png(Test *core) {
    Images *t = (Images *)core; owner(core); t->phase = 1;
    CmdyRenderCompletion *tickets[1022];
    for (unsigned i = 0; i < 1022; i++) {
        tickets[i] = cmdy_render_worker_prepare_completion(core->worker, core, cancelled, no_dispose); assert(tickets[i]);
    }
    // One close ticket plus 1022 holds leaves room for GPU completion only.
    assert(cmdy_render_worker_outstanding_completions(core->worker) == 1023);
    assert(cmdy_gpu_draw(core->gpu, &core->frame));
    assert(cmdy_render_worker_outstanding_completions(core->worker) == 1024);
    for (unsigned i = 0; i < 1022; i++) cmdy_render_worker_cancel_completion(tickets[i]);
}
static void retry_png(Test *core) {
    Images *t = (Images *)core; owner(core); assert(core->cancellations == 1022 && !t->decoded);
    t->phase = 2; assert(cmdy_gpu_draw(core->gpu, &core->frame));
}
static void draw_rgba(Test *core) {
    Images *t = (Images *)core; owner(core); t->phase = 3; assert(cmdy_gpu_draw(core->gpu, &core->frame));
}
static void reject_without_scope(Test *t) {
    assert(scope_depth == 0 && ![NSThread isMainThread]); char error[512] = {0};
    assert(!cmdy_gpu_create_on_worker(t->worker, t->device, MTLPixelFormatBGRA8Unorm, 1, 1, error, sizeof(error)));
    assert(strstr(error, "callback scope")); cmdy_render_worker_stop(t->worker);
}
int main(void) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice(); assert(device);
        dispatch_semaphore_t ready = dispatch_semaphore_create(0), begin = dispatch_semaphore_create(0);
        Images png = {.ready = ready, .begin = begin, .phase_done = dispatch_semaphore_create(0)};
        Images raw = {.ready = ready, .begin = begin, .phase_done = dispatch_semaphore_create(0), .input = {.kind = 1}};
        png.core.device = raw.core.device = (__bridge const void *)device;
        png.core.worker = cmdy_render_worker_create_with_scope(pool); raw.core.worker = cmdy_render_worker_create_with_scope(pool);
        assert(png.core.worker && raw.core.worker); cmdy_gpu_shared_reset(); size_t before = cmdy_gpu_shared_constructions();
        Call first = {.test = &png.core, .fn = initialize_images, .done = dispatch_semaphore_create(0)};
        Call second = {.test = &raw.core, .fn = initialize_images, .done = dispatch_semaphore_create(0)};
        assert(cmdy_render_worker_submit(png.core.worker, 1, &first, run, dispose));
        assert(cmdy_render_worker_submit(raw.core.worker, 1, &second, run, dispose));
        wait_for(ready); wait_for(ready); dispatch_semaphore_signal(begin); dispatch_semaphore_signal(begin);
        wait_for(first.done); wait_for(second.done); assert(cmdy_gpu_shared_constructions() == before + 1);
        invoke(&png.core, limited_png); wait_for(png.phase_done);
        invoke(&raw.core, draw_rgba); invoke(&png.core, retry_png);
        wait_for(raw.phase_done); wait_for(png.phase_done);
        assert(cmdy_render_worker_destroy(raw.core.worker)); assert(cmdy_render_worker_destroy(png.core.worker));
        assert(png.decoded && png.first_draw_done && !raw.decoded);
        Test unscoped = {.device = (__bridge const void *)device, .worker = cmdy_render_worker_create()}; assert(unscoped.worker);
        invoke(&unscoped, reject_without_scope); assert(cmdy_render_worker_destroy(unscoped.worker));
        cmdy_gpu_shared_reset();
        puts("GPU image ownership: simultaneous creation, PNG capacity retry and pixels, RGBA pixels, scope rejection PASS");
    }
    return 0;
}
