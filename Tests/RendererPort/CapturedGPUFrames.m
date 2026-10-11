#define main gpu_owner_fixture_main
#include "GPUWorkerOwnership.m"
#undef main
#include "cmdy_render_frame_input.h"
#include "cmdy_render_image_bridge.h"

enum { W = 120, H = 24, BYTES = W * H * 4 };
typedef struct Captured {
    Test core;
    CmdyRenderRowInput reference_input;
    CmdyRenderOwnedFrameInput *base, *pending, *redraw;
    dispatch_semaphore_t done;
    uint8_t reference[BYTES];
    unsigned phase;
    bool decoded, gpu_done;
    uint64_t rebuilt, reused;
} Captured;
static void pixels(Captured *t, uint8_t *bytes) {
    owner(&t->core);
    [(__bridge id<MTLTexture>)t->core.texture getBytes:bytes bytesPerRow:W * 4
        fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
}
static void sample(const uint8_t *bytes, unsigned x, unsigned r, unsigned g, unsigned b) {
    const uint8_t *p = bytes + (2 * W + x) * 4;
    assert(p[0] == b && p[1] == g && p[2] == r && p[3] == 255);
}
static void captured_event(void *context, uint32_t event_kind) {
    Captured *t = context; owner(&t->core);
    if (event_kind == 2) {
        assert(t->phase == 5 && !t->decoded); t->decoded = true;
    } else {
        assert(event_kind == 1);
        uint8_t bytes[BYTES]; pixels(t, bytes);
        switch (t->phase) {
            case 0: {
                memcpy(t->reference, bytes, BYTES);
                const uint8_t *p = bytes + (2 * W + 98) * 4;
                // The reference is the existing decoder/upload behavior; do
                // not assume a premultiplication convention for Metal's loader.
                assert(p[2] > 0 && p[1] > 0 && p[0] > 0 && p[3] == 255);
                fprintf(stderr, "legacy translucent reference BGRA: %u %u %u %u\n", p[0], p[1], p[2], p[3]);
                break;
            }
            case 1: case 2: assert(memcmp(bytes, t->reference, BYTES) == 0); break;
            case 3: assert(memcmp(bytes + (2 * W + 86) * 4, t->reference + (2 * W + 98) * 4, 4) == 0); sample(bytes, 98, 0, 0, 0); break;
            case 4: sample(bytes, 98, 0, 0, 255); break;
            case 5: assert(!t->gpu_done); t->gpu_done = true; break;
            case 6: sample(bytes, 98, 0, 255, 0); break;
            case 7: sample(bytes, 98, 0, 0, 0); break;
            default: assert(false);
        }
        if (t->phase != 5) { dispatch_semaphore_signal(t->done); return; }
    }
    if (t->decoded && t->gpu_done) {
        t->phase = 6;
        assert(cmdy_gpu_draw_captured(t->core.gpu, t->redraw, NULL, t->core.pass));
        cmdy_render_frame_input_release(t->redraw); t->redraw = NULL;
    }
}
static void reference_draw(Test *core) {
    Captured *t = (Captured *)core; initialize(core);
    cmdy_gpu_set_event(core->gpu, captured_event, t);
    cmdy_gpu_apple_release(core->pass); cmdy_gpu_apple_release(core->texture);
    core->texture = cmdy_gpu_apple_texture(core->device, W, H, 0, MTLPixelFormatBGRA8Unorm, 1, 0);
    core->pass = cmdy_gpu_apple_pass(core->texture); assert(core->texture && core->pass);
    const CmdyRenderFrameInput *captured = cmdy_render_frame_input_view(t->base);
    const CmdyRenderFrameRowInput *row = captured->rows;
    core->row = row->placement;
    core->row.entry = cmdy_gpu_row_resolve(core->gpu, &row->key, row->revision, &t->reference_input, NULL, 0, NULL, 0);
    assert(core->row.entry);
    // Reference follows the normal source bridge's NSImage -> Metal upload,
    // independently of the new encoded-image cache and frame-row binding.
    const CmdyRenderImageInput *pixels = cmdy_render_image_input_view(row->images[0].payload);
    assert(pixels->byte_count == 4 && pixels->bytes[3] == 128);
    NSImage *legacy = CFBridgingRelease(cmdy_image_bridge_decode(pixels->kind, pixels->bytes, pixels->byte_count,
        pixels->width, pixels->height, 12, 12)); assert(legacy);
    const void *texture = cmdy_gpu_apple_decode_image(core->device, (__bridge const void *)legacy); assert(texture);
    CmdyGpuRowView view; cmdy_gpu_row_view(core->row.entry, &view); assert(view.color_layer_count == 0);
    CmdyGpuColorLayer layer = {.texture = texture, .rect = {96, 0, 12, 12}};
    view.color_layers = &layer; view.color_layer_count = 1;
    core->row.entry = cmdy_gpu_row_import(core->gpu, &row->key, &view); assert(core->row.entry);
    cmdy_gpu_apple_release(texture);
    core->frame = captured->parameters; core->frame.pass = core->pass;
    core->frame.rows = &core->row; core->frame.row_count = 1;
    assert(cmdy_gpu_draw(core->gpu, &core->frame));
}
static void captured_draw(Test *core) {
    Captured *t = (Captured *)core; owner(core);
    uint64_t rebuilt = cmdy_gpu_counter(1), reused = cmdy_gpu_counter(2);
    assert(cmdy_gpu_draw_captured(core->gpu, t->pending, NULL, core->pass));
    if (t->phase == 2) { assert(cmdy_gpu_counter(1) == rebuilt); assert(cmdy_gpu_counter(2) == reused + 1); }
    if (t->phase == 3 || t->phase == 4) assert(cmdy_gpu_counter(1) == rebuilt + 1);
    cmdy_render_frame_input_release(t->pending); t->pending = NULL;
}
static void reject_epoch(Test *core) {
    Captured *t = (Captured *)core; owner(core);
    uint64_t rebuilt = cmdy_gpu_counter(1), reused = cmdy_gpu_counter(2);
    assert(!cmdy_gpu_draw_captured(core->gpu, t->pending, NULL, core->pass));
    assert(cmdy_gpu_counter(1) == rebuilt && cmdy_gpu_counter(2) == reused);
    cmdy_render_frame_input_release(t->pending); t->pending = NULL;
}
static void close_pending(Test *core) {
    Captured *t = (Captured *)core; owner(core); t->phase = 8;
    size_t attempts = cmdy_gpu_image_attempts(core->gpu);
    assert(cmdy_gpu_draw_captured(core->gpu, t->pending, NULL, core->pass));
    // The preceding empty frame pruned the PNG texture; this starts a new job.
    assert(cmdy_gpu_image_attempts(core->gpu) == attempts + 1 && cmdy_gpu_image_pending(core->gpu) == 1);
    cmdy_render_frame_input_release(t->pending); t->pending = NULL;
    cmdy_gpu_destroy(core->gpu); core->gpu = NULL;
    release_targets(core); cmdy_render_worker_stop(core->worker);
}
static void limited_owned_png(Test *core) {
    Captured *t = (Captured *)core; owner(core); t->phase = 7;
    CmdyRenderCompletion *tickets[1022];
    for (unsigned i = 0; i < 1022; i++) {
        tickets[i] = cmdy_render_worker_prepare_completion(core->worker, core, cancelled, no_dispose); assert(tickets[i]);
    }
    size_t attempts = cmdy_gpu_image_attempts(core->gpu);
    captured_draw(core); // GPU gets the last slot, so image decode must defer.
    assert(cmdy_gpu_image_attempts(core->gpu) == attempts && cmdy_gpu_image_pending(core->gpu) == 0);
    for (unsigned i = 0; i < 1022; i++) cmdy_render_worker_cancel_completion(tickets[i]);
}
static CmdyRenderOwnedFrameInput *variant(CmdyRenderOwnedFrameInput *base, intptr_t col,
    CmdyRenderOwnedImageInput *image, uint64_t surface, uint64_t epoch, bool empty) {
    CmdyRenderFrameInput input = *cmdy_render_frame_input_view(base);
    CmdyRenderFrameRowInput row = input.rows[0]; CmdyRenderFrameImageInput placement = row.images[0];
    if (image) placement.payload = image;
    placement.placement.col = col; row.images = &placement;
    input.rows = empty ? NULL : &row; input.row_count = empty ? 0 : 1;
    input.identity.surface = surface; input.identity.epoch = epoch; input.identity.sequence++;
    uint32_t status = 99; CmdyRenderOwnedFrameInput *result = cmdy_render_frame_input_capture(&input, &status);
    assert(result && status == 0); return result;
}
static CmdyRenderOwnedImageInput *rgba_image(uint8_t *bytes, uint8_t identity) {
    CmdyRenderImageInput input = {.kind = 1, .bytes = bytes, .byte_count = 4, .width = 1, .height = 1}; input.identity[0] = identity;
    uint32_t status = 99; CmdyRenderOwnedImageInput *result = cmdy_render_image_input_capture(&input, &status);
    assert(result && status == 0); return result;
}
int main(void) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice(); assert(device);
        Captured t = {.done = dispatch_semaphore_create(0)}; t.core.device = (__bridge const void *)device;
        t.core.worker = cmdy_render_worker_create_with_scope(pool); assert(t.core.worker);
        NSFont *font = [NSFont fontWithName:@"Menlo" size:14]; assert(font);
        NSMutableAttributedString *text = [[NSMutableAttributedString alloc] initWithString:@"Aé𝄞"
            attributes:@{NSFontAttributeName:font, NSForegroundColorAttributeName:NSColor.whiteColor, NSUnderlineStyleAttributeName:@1}];
        intptr_t boundaries[] = {0, 1, 2, 4};
        CmdyRenderTextSegment segment = {.attributed_string = (__bridge const void *)text, .column_width = 1,
            .character_count = 3, .boundaries = boundaries, .boundary_count = 4, .has_boundaries = 1};
        t.reference_input = (CmdyRenderRowInput){.segments = &segment, .segment_count = 1, .cols = 10, .width = W, .height = H,
            .cell_width = 12, .cell_height = H, .scale = 1, .underline_position = 2, .underline_thickness = 1,
            .normal_font = (__bridge const void *)font, .foreground = (__bridge const void *)NSColor.whiteColor,
            .coverage_exponent = 1.35, .snaps_y = 1, .ascii_caching = 1, .font_caching = 1};
        uint32_t status = 99;
        CmdyRenderOwnedRowInput *owned_text = cmdy_render_input_capture(&t.reference_input, &status); assert(owned_text && status == 0);
        uint8_t red[] = {200, 80, 30, 128}, blue[] = {0, 0, 255, 255};
        CmdyRenderOwnedImageInput *red_image = rgba_image(red, 1), *blue_image = rgba_image(blue, 2);
        CmdyRenderFrameImageInput image = {.payload = red_image, .placement = {.col = 8, .width = 12, .height = 12}};
        CmdyRenderFrameRowInput row = {.key = {.absolute_row = 0, .version = 77, .cols = 10, .width = W, .height = H, .font_name = "Menlo"},
            .font_name_bytes = 5, .revision = {77, 7}, .text = owned_text, .images = &image, .image_count = 1,
            .placement = {.has_selection = 1, .selection_lower = 1, .selection_upper = 2}};
        CmdyRenderFrameInput input = {.identity = {41, 1, 1}, .rows = &row, .row_count = 1,
            .parameters = {.width = W, .height = H, .scale = 1, .cell_width = 12, .cell_height = H,
                .grid_rows = 1, .grid_cols = 10, .image_scale = 1, .background = {0, 0, 0, 1}, .selection = {0, 0, 0.5, 1},
                .cursor_valid = 1, .cursor_col = 4, .cursor_style = 1, .caret_focused = 1, .cursor_natural_height = 18,
                .caret = {0.5, 0.5, 0.5, 1}, .underline_thickness = 1, .now = 1}};
        t.base = cmdy_render_frame_input_capture(&input, &status); assert(t.base && status == 0);
        // A raw owned-image field cannot bypass the frame packet's lifetime rule.
        image.placement.owned_image = red_image;
        assert(!cmdy_render_frame_input_capture(&input, &status) && status == CMDY_RENDER_INPUT_INVALID);
        image.placement.owned_image = NULL;
        invoke(&t.core, reference_draw); wait_for(t.done);
        [text replaceCharactersInRange:NSMakeRange(0, text.length) withString:@"producer changed"];
        text = nil; memset(boundaries, 0, sizeof(boundaries)); memset(red, 0, sizeof(red)); memset(blue, 0, sizeof(blue));
        t.reference_input = (CmdyRenderRowInput){0}; segment = (CmdyRenderTextSegment){0};
        cmdy_render_input_release(owned_text); cmdy_render_image_input_release(red_image);
        t.phase = 1; t.pending = cmdy_render_frame_input_retain(t.base); invoke(&t.core, captured_draw); wait_for(t.done);
        t.phase = 2; t.pending = cmdy_render_frame_input_retain(t.base); invoke(&t.core, captured_draw); wait_for(t.done);
        t.phase = 3; t.pending = variant(t.base, 7, NULL, 41, 1, false); invoke(&t.core, captured_draw); wait_for(t.done);
        t.phase = 4; t.pending = variant(t.base, 8, blue_image, 41, 1, false); invoke(&t.core, captured_draw); wait_for(t.done);
        cmdy_render_image_input_release(blue_image);
        assert(cmdy_render_worker_invalidate(t.core.worker) == 2);
        t.pending = cmdy_render_frame_input_retain(t.base); invoke(&t.core, reject_epoch);
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:1 pixelsHigh:1
            bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:4 bitsPerPixel:32]; assert(rep);
        const uint8_t green[] = {0, 255, 0, 255}; memcpy(rep.bitmapData, green, 4);
        NSMutableData *png = [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] mutableCopy]; assert(png.length);
        CmdyRenderImageInput png_source = {.kind = 0, .bytes = png.bytes, .byte_count = png.length}; png_source.identity[0] = 3;
        CmdyRenderOwnedImageInput *png_image = cmdy_render_image_input_capture(&png_source, &status); assert(png_image && status == 0);
        CmdyRenderOwnedFrameInput *png_frame = variant(t.base, 8, png_image, 42, 2, false);
        cmdy_render_image_input_release(png_image); [png resetBytesInRange:NSMakeRange(0, png.length)]; png = nil; rep = nil;
        t.pending = cmdy_render_frame_input_retain(png_frame); invoke(&t.core, limited_owned_png); wait_for(t.done);
        t.phase = 5; t.pending = cmdy_render_frame_input_retain(png_frame); t.redraw = cmdy_render_frame_input_retain(png_frame);
        invoke(&t.core, captured_draw); wait_for(t.done);
        assert(t.phase == 6 && t.decoded && t.gpu_done && t.redraw == NULL);
        t.phase = 7; t.pending = variant(png_frame, 8, NULL, 42, 2, true); invoke(&t.core, captured_draw); wait_for(t.done);
        // The empty pruning frame advanced the committed sequence. Closing
        // with a pending image needs a fresh frame, not the older PNG packet.
        CmdyRenderFrameInput closing = *cmdy_render_frame_input_view(png_frame);
        closing.identity.sequence += 2;
        t.pending = cmdy_render_frame_input_capture(&closing, &status); assert(t.pending && status == 0);
        cmdy_render_frame_input_release(png_frame);
        cmdy_render_frame_input_release(t.base); t.base = NULL;
        invoke(&t.core, close_pending); assert(cmdy_render_worker_destroy(t.core.worker));
        assert(t.pending == NULL && t.core.gpu == NULL);
        cmdy_gpu_shared_reset();
        puts("captured GPU frames: Unicode/cursor/selection parity, immutable lifetimes, row reuse, image changes, PNG, pruning, epochs and close PASS");
    }
    return 0;
}
