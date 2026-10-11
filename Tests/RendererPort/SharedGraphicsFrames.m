// Headless pixel equivalence for copied versus shared global graphics payloads.
#define main gpu_owner_predecessor_main
#include "GPUWorkerOwnership.m"
#undef main
#include "cmdy_render_frame_input.h"

typedef struct GraphicsScene {
    Test core;
    CmdyRenderOwnedFrameInput *frame;
    dispatch_semaphore_t done;
    bool png, decoded, in_flight, redrawn;
    uint8_t pixels[8 * 8 * 4];
} GraphicsScene;

static void graphics_draw(GraphicsScene *scene) {
    scene->in_flight = true;
    assert(cmdy_gpu_draw_captured(scene->core.gpu, scene->frame, NULL, scene->core.pass));
}
static void graphics_event(void *context, uint32_t kind) {
    GraphicsScene *scene = context; owner(&scene->core);
    if (kind == 2) scene->decoded = true;
    else { assert(kind == 1 && scene->in_flight); scene->in_flight = false; }
    if (scene->in_flight || !scene->decoded) return;
    if (scene->png && !scene->redrawn) {
        scene->redrawn = true; graphics_draw(scene); return;
    }
    [(__bridge id<MTLTexture>)scene->core.texture getBytes:scene->pixels bytesPerRow:8 * 4
        fromRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0];
    // A nonempty image must actually have reached the texture.
    assert(scene->pixels[2] > 0 && scene->pixels[3] == 255);
    dispatch_semaphore_signal(scene->done);
}
static void graphics_begin(Test *core) {
    GraphicsScene *scene = (GraphicsScene *)core;
    initialize(core);
    cmdy_gpu_set_event(core->gpu, graphics_event, scene);
    graphics_draw(scene);
}
static void graphics_end(Test *core) {
    owner(core); cmdy_gpu_destroy(core->gpu); core->gpu = NULL;
    release_targets(core); cmdy_render_worker_stop(core->worker);
}
static void render_graphics(id<MTLDevice> device, CmdyRenderOwnedFrameInput *frame, bool png, uint8_t *pixels) {
    GraphicsScene scene = {.frame = frame, .done = dispatch_semaphore_create(0), .png = png, .decoded = !png};
    scene.core.device = (__bridge const void *)device;
    scene.core.worker = cmdy_render_worker_create_with_scope(pool); assert(scene.core.worker);
    invoke(&scene.core, graphics_begin); wait_for(scene.done);
    memcpy(pixels, scene.pixels, sizeof(scene.pixels));
    invoke(&scene.core, graphics_end); assert(cmdy_render_worker_destroy(scene.core.worker));
}

int main(void) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice(); assert(device);
        const uint8_t rgba[] = {200, 80, 30, 128};
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:1 pixelsHigh:1
            bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace
            bytesPerRow:4 bitsPerPixel:32]; assert(rep); memcpy(rep.bitmapData, rgba, sizeof(rgba));
        NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}]; assert(png.length);
        NSFont *font = [NSFont fontWithName:@"Menlo" size:8]; assert(font);
        for (unsigned format = 0; format < 2; format++) for (unsigned alternate = 0; alternate < 2; alternate++) {
            const bool is_png = format == 1;
            const uint8_t *bytes = is_png ? png.bytes : rgba;
            size_t count = is_png ? png.length : sizeof(rgba);
            uint32_t status = 99, live = 7;
            CmdyZigGraphics *store = cmdy_zig_graphics_create(); assert(store);
            CmdyZigPayload *payload = cmdy_zig_payload_create_host(format, bytes, count, 1, 1, NULL, NULL); assert(payload);
            CmdyZigStoredImage *image = cmdy_zig_stored_image_create(payload, 7, 0, 0, 1, 1); assert(image);
            assert(cmdy_zig_graphics_store(store, image) == 1);
            CmdyZigPlacement placement = {.image_id = 7, .placement_id = 9 + alternate,
                .cols = 1, .rows = 1, .is_virtual = 1, .is_alternate_buffer = alternate};
            assert(cmdy_zig_graphics_place(store, &placement) == 1);
            CmdyRenderOwnedGraphicsInput *graphics = cmdy_render_graphics_input_capture(store, &status); assert(graphics && status == 0);
            CmdyRenderRowInput text = {.cols = 1, .width = 8, .height = 8, .cell_width = 8, .cell_height = 8,
                .scale = 1, .normal_font = (__bridge const void *)font, .foreground = (__bridge const void *)NSColor.whiteColor,
                .coverage_exponent = 1.35, .snaps_y = 1};
            CmdyRenderOwnedRowInput *owned_text = cmdy_render_input_capture(&text, &status); assert(owned_text && status == 0);
            CmdyGpuPlaceholder placeholder = {.image_id = 7, .placement_id = 9 + alternate};
            CmdyRenderFrameRowInput row = {.key = {.absolute_row = 0, .version = 9, .cols = 1, .width = 8, .height = 8, .font_name = "Menlo"},
                .font_name_bytes = 5, .text = owned_text, .placeholders = &placeholder, .placeholder_count = 1};
            CmdyGpuKittyImage raw_image = {.image_id = 7, .kind = is_png ? 0 : 1, .bytes = bytes, .byte_count = count,
                .width = is_png ? 0 : 1, .height = is_png ? 0 : 1};
            CmdyGpuKittyPlacement raw_placement = {.image_id = 7, .placement_id = 9 + alternate, .cols = 1, .rows = 1};
            CmdyRenderFrameInput input = {.identity = {41, 1, 1}, .alternate_buffer = alternate,
                .rows = &row, .row_count = 1, .parameters = {.width = 8, .height = 8, .scale = 1,
                    .cell_width = 8, .cell_height = 8, .grid_rows = 1, .grid_cols = 1, .cursor_hidden = 1,
                    .image_scale = 1, .background = {0, 0, 0, 1}, .now = 1,
                    .kitty_images = &raw_image, .kitty_image_count = 1,
                    .kitty_placements = &raw_placement, .kitty_placement_count = 1, .live_kitty_ids = &live, .live_kitty_count = 1}};
            CmdyRenderOwnedFrameInput *copied = cmdy_render_frame_input_capture(&input, &status); assert(copied && status == 0);
            CmdyRenderOwnedFrameRowInput *descriptor = cmdy_render_frame_row_capture(&row, &status); assert(descriptor && status == 0);
            CmdyRenderFrameRowReference reference = {.row = descriptor};
            input.rows = NULL; input.row_count = 0;
            input.parameters.kitty_images = NULL; input.parameters.kitty_image_count = 0;
            input.parameters.kitty_placements = NULL; input.parameters.kitty_placement_count = 0;
            input.parameters.live_kitty_ids = NULL; input.parameters.live_kitty_count = 0;
            CmdyRenderOwnedFrameInput *shared = cmdy_render_frame_input_capture_referenced_graphics(&input, &reference, 1, graphics, &status);
            assert(shared && status == 0);
            CmdyZigPayloadInfo payload_info; assert(cmdy_zig_payload_info(payload, &payload_info) == 0);
            assert(cmdy_render_frame_input_view(shared)->parameters.kitty_images[0].bytes == payload_info.bytes);
            cmdy_render_frame_row_release(descriptor); cmdy_render_input_release(owned_text);
            cmdy_render_graphics_input_release(graphics); cmdy_zig_graphics_free(store);
            cmdy_zig_stored_image_release(image); cmdy_zig_payload_release(payload);
            uint8_t expected[8 * 8 * 4], actual[8 * 8 * 4];
            render_graphics(device, copied, is_png, expected);
            render_graphics(device, shared, is_png, actual);
            assert(memcmp(expected, actual, sizeof(actual)) == 0);
            cmdy_render_frame_input_release(copied); cmdy_render_frame_input_release(shared);
        }
        cmdy_gpu_shared_reset();
        puts("shared global graphics: four exact RGBA/PNG primary/alternate Metal comparisons after producer destruction PASS");
    }
    return 0;
}
