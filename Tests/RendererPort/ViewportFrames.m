// Headless worker equivalence and cache reuse. No windows, PTY or input.
#define main gpu_owner_predecessor_main
#include "GPUWorkerOwnership.m"
#undef main
#include "cmdy_render_frame_input.h"

#ifdef CMDY_VIEWPORT_COLOR_AUDIT
// Only the private diagnostic archive renames the platform implementation.
// Count real conversions without changing the production library or ABI.
static atomic_uint viewport_color_conversions;
extern const void *viewport_original_device_rgb(const void *color);
const void *cmdy_platform_text_color_device_rgb(const void *color) {
    atomic_fetch_add(&viewport_color_conversions, 1);
    return viewport_original_device_rgb(color);
}
#endif

enum { VW = 48, VH = 80, VBYTES = VW * VH * 4 };
typedef struct ViewportScene {
    Test core;
    CmdyRenderOwnedFrameInput *frame, *next;
    dispatch_semaphore_t done;
    unsigned draws;
    uint64_t rebuilt;
    bool native_viewport;
#ifdef CMDY_VIEWPORT_COLOR_AUDIT
    unsigned conversions_before_repeat;
#endif
    uint8_t pixels[2 * VBYTES];
} ViewportScene;
static void viewport_event(void *context, uint32_t kind) {
    ViewportScene *scene = context; owner(&scene->core);
    assert(kind == 1);
    if (++scene->draws == 1 || scene->draws == 3) {
        scene->rebuilt = cmdy_gpu_counter(1);
        assert(scene->rebuilt > 0);
#ifdef CMDY_VIEWPORT_COLOR_AUDIT
        scene->conversions_before_repeat = atomic_load(&viewport_color_conversions);
#endif
        assert(cmdy_gpu_draw_captured(scene->core.gpu, scene->draws == 1 ? scene->frame : scene->next, NULL, scene->core.pass));
        return;
    }
    assert((scene->draws == 2 || scene->draws == 4) && cmdy_gpu_counter(1) == scene->rebuilt);
#ifdef CMDY_VIEWPORT_COLOR_AUDIT
    unsigned conversions = atomic_load(&viewport_color_conversions) - scene->conversions_before_repeat;
    assert(conversions == (scene->native_viewport ? CMDY_VIEWPORT_EXPECT_REPEAT_CONVERSIONS : 0));
#endif
    assert(cmdy_gpu_rows_count(scene->core.gpu) == 4);
    uint8_t *pixels = scene->pixels + (scene->draws == 2 ? 0 : VBYTES);
    [(__bridge id<MTLTexture>)scene->core.texture getBytes:pixels bytesPerRow:VW * 4
        fromRegion:MTLRegionMake2D(0, 0, VW, VH) mipmapLevel:0];
    bool painted = false;
    for (unsigned i = 0; i < VBYTES; i += 4) if (pixels[i] || pixels[i + 1] || pixels[i + 2]) painted = true;
    assert(painted);
    if (scene->draws == 2) {
        assert(cmdy_gpu_draw_captured(scene->core.gpu, scene->next, NULL, scene->core.pass));
        return;
    }
    dispatch_semaphore_signal(scene->done);
}
static void viewport_begin(Test *core) {
    ViewportScene *scene = (ViewportScene *)core; initialize(core);
    cmdy_gpu_apple_release(core->pass); cmdy_gpu_apple_release(core->texture);
    core->texture = cmdy_gpu_apple_texture(core->device, VW, VH, 0, MTLPixelFormatBGRA8Unorm, 1, 0);
    core->pass = cmdy_gpu_apple_pass(core->texture); assert(core->pass);
    cmdy_gpu_counter_set(1, 0);
    cmdy_gpu_set_event(core->gpu, viewport_event, scene);
    assert(cmdy_gpu_draw_captured(core->gpu, scene->frame, NULL, core->pass));
}
static void viewport_end(Test *core) {
    owner(core); cmdy_gpu_destroy(core->gpu); core->gpu = NULL;
    release_targets(core); cmdy_render_worker_stop(core->worker);
}
static void viewport_render(id<MTLDevice> device, CmdyRenderOwnedFrameInput *frame, CmdyRenderOwnedFrameInput *next, uint8_t *pixels, bool native_viewport) {
    ViewportScene scene = {.frame = frame, .next = next, .native_viewport = native_viewport, .done = dispatch_semaphore_create(0)};
    scene.core.device = (__bridge const void *)device;
    scene.core.worker = cmdy_render_worker_create_with_scope(pool); assert(scene.core.worker);
    invoke(&scene.core, viewport_begin); wait_for(scene.done);
    memcpy(pixels, scene.pixels, sizeof(scene.pixels));
    invoke(&scene.core, viewport_end); assert(cmdy_render_worker_destroy(scene.core.worker));
}
static CmdyGpuImagePlacement image_placement(CmdyZigImageInfo v) {
    return (CmdyGpuImagePlacement){.col = v.col, .z_index = v.z_index, .width = v.pixel_width, .height = v.pixel_height,
        .offset_x = v.offset_x, .offset_y = v.offset_y, .kitty_image_id = v.image_id, .has_kitty_id = v.has_image_id, .is_kitty = v.is_kitty};
}
int main(int argc, const char **argv) {
    assert(argc == 1 || argc == 2);
    FILE *output = argc == 2 ? fopen(argv[1], "wx") : NULL;
    assert(argc == 1 || output);
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice(); assert(device);
        NSFont *font = [NSFont fontWithName:@"Menlo" size:14]; assert(font);
        CmdyShapeStyleInput style_input = {0};
        for (unsigned i = 0; i < 4; i++) style_input.fonts[i] = (__bridge const void *)font;
        for (unsigned i = 0; i < 5; i++) style_input.colors[i] = (__bridge const void *)NSColor.whiteColor;
        style_input.colors[1] = (__bridge const void *)NSColor.blackColor;
        intptr_t failed = 2; style_input.failed_rows = &failed; style_input.failed_row_count = 1;
        style_input.colors[3] = (__bridge const void *)NSColor.orangeColor;
        style_input.colors[4] = (__bridge const void *)NSColor.darkGrayColor;
        CmdyShapeStyle *source_style = cmdy_shape_style_create(&style_input); assert(source_style);
        CmdyRenderRowStyle *style = cmdy_render_row_style_capture(source_style, NULL); assert(style);
        cmdy_shape_style_free(source_style);
        CmdyRenderRowInput raster = {.cols = 4, .width = VW, .height = 20, .cell_width = 12, .cell_height = 20,
            .scale = 1, .normal_font = (__bridge const void *)font, .foreground = (__bridge const void *)NSColor.whiteColor,
            .coverage_exponent = 1.35, .snaps_y = 1, .antialias_blocks = 1, .ascii_caching = 1, .font_caching = 1};
        CmdyRenderRowParameters *parameters = cmdy_render_row_parameters_capture(&raster, NULL); assert(parameters);
        for (unsigned variant = 0; variant < 4; variant++)
        for (unsigned images = 0; images < 2; images++) for (unsigned selected = 0; selected < 2; selected++) {
            CmdyZigBuffer *buffer = cmdy_zig_buffer_create(4, 4, 0, 0); assert(buffer);
            const uint32_t scalars[4] = {'A', 0xe9, 0x2588, 0x2500};
            for (unsigned i = 0; i < 4; i++) {
                CmdyZigLine *line = cmdy_zig_buffer_line(buffer, i); assert(line);
                CmdyZigCell cell = {.scalar = scalars[i], .width = 1};
                assert(cmdy_zig_line_set(line, 0, &cell, NULL, 0, 0) == 0);
                assert(cmdy_zig_line_set_metadata(line, 2, i) == 0);
                if (images) {
                    const uint8_t rgba[] = {200, 70, 40, 255};
                    CmdyZigPayload *payload = cmdy_zig_payload_create_host(0, rgba, sizeof(rgba), 1, 1, NULL, NULL); assert(payload);
                    CmdyZigImage *image = cmdy_zig_image_create_host(payload, 4, 4, 1); assert(image);
                    assert(cmdy_zig_line_set_images(line, &image, 1, 1) == 0);
                    cmdy_zig_image_release(image); cmdy_zig_payload_release(payload);
                }
                cmdy_zig_line_release(line);
            }
            int32_t status = 99;
            CmdyZigBufferSnapshot *snapshot = cmdy_zig_buffer_snapshot_capture(buffer, 0, 4, &status); assert(snapshot && status == 0);
            CmdyRenderFrameInput frame = {.identity = {77, 1, 1}, .buffer_line_count = 4,
                .parameters = {.width = VW, .height = VH, .scale = 1, .cell_width = 12, .cell_height = 20,
                    .grid_rows = 4, .grid_cols = 4, .cursor_hidden = 1, .image_scale = 1, .background = {0, 0, 0, 1},
                    .selection = {0.1, 0.3, 0.6, 0.6}, .now = 1}};
            CmdyRenderViewportInput viewport = {.snapshot = snapshot, .style = style, .raster = parameters,
                .key = {.cols = 4, .width = VW, .height = 20, .font_name = "Menlo"}, .font_name_bytes = 5,
                .has_selection = selected, .selection_start_row = 1, .selection_start_col = -2,
                .selection_end_row = 2, .selection_end_col = 99};
            CmdyRenderOwnedFrameInput *actual = cmdy_render_frame_input_capture_viewport(&frame, &viewport, NULL, NULL); assert(actual);
            CmdyRenderFrameRowInput rows[4] = {0}; CmdyRenderFrameImageInput row_images[4] = {0};
            for (unsigned i = 0; i < 4; i++) {
                const CmdyZigLine *line = cmdy_zig_buffer_snapshot_line(snapshot, i);
                rows[i].key = viewport.key; rows[i].key.absolute_row = i;
                rows[i].key.version = cmdy_zig_line_version(line); rows[i].key.line_mode = i; rows[i].font_name_bytes = 5;
                rows[i].text = cmdy_render_input_capture_frozen(line, i, style, parameters, NULL); assert(rows[i].text);
                rows[i].placement = (CmdyGpuFrameRow){.display_index = i, .source_row = i, .line_mode = i,
                    .has_selection = selected && (i == 1 || i == 2), .selection_lower = 0, .selection_upper = 3};
                if (images) {
                    CmdyZigImage *image = cmdy_zig_line_image_get(line, 0); assert(image);
                    CmdyZigImageInfo info; CmdyZigPayloadInfo payload;
                    assert(cmdy_zig_image_info(image, &info) == 0);
                    assert(cmdy_zig_payload_info(cmdy_zig_image_payload(image), &payload) == 0);
                    CmdyRenderImageInput image_input = {.kind = 1, .bytes = payload.bytes, .byte_count = payload.count,
                        .width = payload.width, .height = payload.height};
                    for (unsigned n = 0; n < 8; n++) {
                        image_input.identity[n] = (uint8_t)(info.identity_high >> ((7 - n) * 8));
                        image_input.identity[n + 8] = (uint8_t)(info.identity_low >> ((7 - n) * 8));
                    }
                    row_images[i].payload = cmdy_render_image_input_capture(&image_input, NULL); assert(row_images[i].payload);
                    row_images[i].placement = image_placement(info);
                    rows[i].images = &row_images[i]; rows[i].image_count = 1;
                    cmdy_zig_image_release(image);
                }
            }
            frame.rows = rows; frame.row_count = 4;
            CmdyRenderOwnedFrameInput *expected = cmdy_render_frame_input_capture(&frame, NULL); assert(expected);
            // Change placement without touching the line version. A cache keyed
            // only by row revision would incorrectly keep the first image.
            if (images) {
                CmdyZigLine *line = cmdy_zig_buffer_line(buffer, 0); assert(line);
                uint64_t version = cmdy_zig_line_version(line);
                CmdyZigImage *image = cmdy_zig_line_image_get(line, 0); assert(image);
                CmdyZigImageInfo info; assert(cmdy_zig_image_info(image, &info) == 0);
                info.col = 2; info.offset_x = 1;
                assert(cmdy_zig_image_set_info(image, &info) == 0);
                assert(cmdy_zig_line_version(line) == version);
                row_images[0].placement = image_placement(info);
                cmdy_zig_image_release(image); cmdy_zig_line_release(line);
            }
            CmdyZigBufferSnapshot *next_snapshot = cmdy_zig_buffer_snapshot_capture(buffer, 0, 4, &status); assert(next_snapshot && status == 0);
            viewport.snapshot = next_snapshot; viewport.has_selection = !selected;
            CmdyRenderRowParameters *next_parameters = NULL;
            if (variant != 0) {
                CmdyRenderRowInput next_raster = raster;
                if (variant == 2) next_raster.foreground = (__bridge const void *)NSColor.greenColor;
                if (variant == 3) next_raster.cell_width = 10;
                next_parameters = cmdy_render_row_parameters_capture(&next_raster, NULL); assert(next_parameters);
                viewport.raster = next_parameters;
                for (unsigned i = 0; i < 4; i++) {
                    cmdy_render_input_release(rows[i].text);
                    rows[i].text = cmdy_render_input_capture_frozen(cmdy_zig_buffer_snapshot_line(next_snapshot, i), i, style, next_parameters, NULL);
                    assert(rows[i].text);
                }
            }
            for (unsigned i = 0; i < 4; i++) rows[i].placement.has_selection = !selected && (i == 1 || i == 2);
            frame.identity.sequence = 2;
            CmdyRenderOwnedFrameInput *expected_next = cmdy_render_frame_input_capture(&frame, NULL); assert(expected_next);
            frame.rows = NULL; frame.row_count = 0;
            CmdyRenderOwnedFrameInput *actual_next = cmdy_render_frame_input_capture_viewport(&frame, &viewport, NULL, NULL); assert(actual_next);
            cmdy_render_row_parameters_release(next_parameters);
            for (unsigned i = 0; i < 4; i++) { cmdy_render_input_release(rows[i].text); cmdy_render_image_input_release(row_images[i].payload); }
            cmdy_zig_buffer_snapshot_release(snapshot); cmdy_zig_buffer_snapshot_release(next_snapshot); cmdy_zig_buffer_free(buffer);
            uint8_t reference[2 * VBYTES], result[2 * VBYTES];
            viewport_render(device, expected, expected_next, reference, false); viewport_render(device, actual, actual_next, result, true);
            assert(memcmp(reference, result, sizeof(result)) == 0);
            if (output) assert(fwrite(result, sizeof(result), 1, output) == 1);
            assert(memcmp(result, result + VBYTES, VBYTES) != 0);
            cmdy_render_frame_input_release(expected); cmdy_render_frame_input_release(actual);
            cmdy_render_frame_input_release(expected_next); cmdy_render_frame_input_release(actual_next);
        }
        cmdy_render_row_parameters_release(parameters); cmdy_render_row_style_release(style); cmdy_gpu_shared_reset();
        puts("viewport worker: 32 exact Metal scenes, DEC modes, selection/image geometry, equivalent and changed raster packets, failed rows, producer destruction and cache reuse PASS");
#ifdef CMDY_VIEWPORT_COLOR_AUDIT
        printf("viewport repeat color conversions: %u per four-row draw PASS\n", CMDY_VIEWPORT_EXPECT_REPEAT_CONVERSIONS);
#endif
    }
    if (output) assert(fclose(output) == 0);
    return 0;
}
