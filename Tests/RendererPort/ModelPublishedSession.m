// Actual render-owner and Metal checks. No app, window, PTY or main-run-loop service.
#define CMDY_PUBLICATION_CONTRACT_NAME predecessor_publication_contract
#include "PublishedSession.m"

static atomic_uint payload_releases;
static const uint8_t payload_bytes[] = {255, 0, 0, 255};
static void release_payload(void *context) {
    assert(context == &payload_releases);
    atomic_fetch_add(&payload_releases, 1);
}
static CmdyZigBufferSnapshot *model_rows(uint32_t rgb, bool image) {
    CmdyZigBuffer *buffer = cmdy_zig_buffer_create(1, 1, 0, 0); assert(buffer);
    CmdyZigLine *line = cmdy_zig_buffer_line(buffer, 0); assert(line);
    CmdyZigCell cell = {.scalar = ' ', .width = 1, .bg = 0x02000000 | rgb};
    assert(cmdy_zig_line_set(line, 0, &cell, NULL, 0, 0) == 0);
    if (image) {
        CmdyZigPayload *payload = cmdy_zig_payload_create_host(0, payload_bytes, sizeof(payload_bytes), 1, 1,
            &payload_releases, release_payload); assert(payload);
        CmdyZigImage *entry = cmdy_zig_image_create_host(payload, 1, 1, 100); assert(entry);
        assert(cmdy_zig_line_set_images(line, &entry, 1, 1) == 0);
        cmdy_zig_image_release(entry); cmdy_zig_payload_release(payload);
    }
    cmdy_zig_line_release(line);
    int32_t status = 99;
    CmdyZigBufferSnapshot *snapshot = cmdy_zig_buffer_snapshot_capture(buffer, 0, 1, &status);
    assert(snapshot && status == 0); cmdy_zig_buffer_free(buffer);
    return snapshot;
}
static CmdyRenderModelInput model_input(CmdyZigBufferSnapshot *rows, uint64_t generation) {
    return (CmdyRenderModelInput){.snapshot = rows, .generation = generation,
        .rows = 1, .cols = 1, .buffer_line_count = 1, .cursor_hidden = 1};
}
static bool publish_model(SessionTest *t, uint64_t generation, uint32_t rgb, bool image) {
    CmdyZigBufferSnapshot *rows = model_rows(rgb, image);
    CmdyRenderModelInput input = model_input(rows, generation);
    bool accepted = cmdy_render_session_publish_model(t->session, &input);
    cmdy_zig_buffer_snapshot_release(rows);
    return accepted;
}
static void publish_ui(SessionTest *t, CmdyRenderSessionUpdate requested, CAMetalLayer *layer,
                       uint64_t generation, uint32_t rgb) {
    NSFont *font = [NSFont fontWithName:@"Menlo" size:8]; assert(font);
    CmdyShapeStyleInput source = {0};
    for (unsigned i = 0; i < 4; i++) source.fonts[i] = (__bridge const void *)font;
    for (unsigned i = 0; i < 5; i++) source.colors[i] = (__bridge const void *)NSColor.whiteColor;
    source.colors[1] = (__bridge const void *)NSColor.blackColor;
    CmdyShapeStyle *resolved = cmdy_shape_style_create(&source); assert(resolved);
    CmdyRenderRowStyle *style = cmdy_render_row_style_capture(resolved, NULL); assert(style);
    cmdy_shape_style_free(resolved);
    CmdyRenderRowInput raster = {.cols = 1, .width = 8, .height = 8, .cell_width = 8,
        .cell_height = 8, .scale = 1, .normal_font = (__bridge const void *)font,
        .foreground = (__bridge const void *)NSColor.whiteColor, .coverage_exponent = 1.35};
    CmdyRenderRowParameters *parameters = cmdy_render_row_parameters_capture(&raster, NULL); assert(parameters);
    CmdyZigBufferSnapshot *rows = model_rows(rgb, false);
    CmdyRenderViewportInput viewport = {.snapshot = rows, .style = style, .raster = parameters,
        .key = {.cols = 1, .width = 8, .height = 8, .font_name = "Menlo"},
        .font_name_bytes = 5, .model_generation = generation};
    CmdyRenderFrameInput input = {.identity = requested.identity, .buffer_line_count = 1};
    input.parameters = (CmdyGpuFrame){.width = 8, .height = 8, .scale = 1, .cell_width = 8,
        .cell_height = 8, .grid_rows = 1, .grid_cols = 1, .cursor_hidden = 1,
        .image_scale = 1, .background = {0, 0, 1, 1}, .now = environment().now};
    CmdyRenderOwnedFrameInput *frame = cmdy_render_frame_input_capture_viewport(&input, &viewport, NULL, NULL);
    assert(frame);
    assert(cmdy_render_session_publish_layer(t->session, frame, requested.source_revision,
        (__bridge const void *)layer, 0, environment(), NULL, NULL, NULL));
    cmdy_render_frame_input_release(frame);
    cmdy_zig_buffer_snapshot_release(rows); cmdy_render_row_style_release(style);
    cmdy_render_row_parameters_release(parameters);
    assert(matching(t, CMDY_SESSION_FRAME, 0).success); gpu_done(t);
}
static CmdyRenderSessionUpdate model_frame(SessionTest *t) {
    for (unsigned i = 0; i < 256; i++) {
        CmdyRenderSessionUpdate value = next(t);
        assert(value.kind != CMDY_SESSION_CAPTURE && value.kind != CMDY_SESSION_ERROR);
        assert(!(value.actions.flags & (CMDY_RENDER_INVALIDATE_VIEW | CMDY_RENDER_QUEUE_SERVICE |
            CMDY_RENDER_DRAW_MANUAL | CMDY_RENDER_START_COALESCED | CMDY_RENDER_START_RECOVERY)));
        if (value.kind == CMDY_SESSION_FRAME) { assert(value.success); gpu_done(t); return value; }
    }
    assert(false); return (CmdyRenderSessionUpdate){0};
}

#ifndef CMDY_MODEL_CONTRACT_NAME
#define CMDY_MODEL_CONTRACT_NAME main
#endif
int CMDY_MODEL_CONTRACT_NAME(void) {
    completed = dispatch_semaphore_create(0); continue_completion = dispatch_semaphore_create(0);
    encoded = dispatch_semaphore_create(0); continue_encode = dispatch_semaphore_create(0);
    feedback_registered = dispatch_semaphore_create(0);
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice(); assert(device);
        SessionTest t; start_layer(&t, device);
        LayerFixture *layer = layer_for(&t, device);
        CmdyRenderSessionUpdate initial = capture(&t);
        publish_ui(&t, initial, layer, 1, 0xff0000);
        layer_pixels(device, layer->lastTexture, 255, 0, 0);
        assert(publish_model(&t, 2, 0x00ff00, false));
        CmdyRenderSessionUpdate updated = model_frame(&t);
        assert(updated.source_revision == initial.source_revision + 1);
        assert(updated.identity.sequence > initial.identity.sequence);
        layer_pixels(device, layer->lastTexture, 0, 255, 0);
        puts("Model publication: actual Metal pixels update without host capture, view invalidation or main-loop service PASS");

        // All 256 snapshots are produced while the render owner cannot run.
        // Replaced payloads must release immediately; only the newest survives.
        post(&t, CMDY_SESSION_EVENT, CMDY_RENDER_RESET_PACING, 98); wait_for(t.blocked);
        for (uint64_t i = 3; i <= 258; i++) assert(publish_model(&t, i, 0x00ff00, true));
        assert(atomic_load(&payload_releases) == 255);
        assert(!publish_model(&t, 258, 0xff0000, false));
        assert(!publish_model(&t, 1, 0xff0000, false));
        dispatch_semaphore_signal(t.unblock);
        updated = model_frame(&t);
        assert(updated.source_revision == initial.source_revision + 257);
        layer_pixels(device, layer->lastTexture, 0, 255, 0);
        assert(publish_model(&t, 259, 0x0000ff, false));
        (void)model_frame(&t);
        (void)inspect_layer(&t);
        assert(atomic_load(&payload_releases) == 256);
        layer_pixels(device, layer->lastTexture, 0, 0, 255);
        puts("Model publication: 256 queued snapshots coalesce, stale generations reject and every replaced image payload releases PASS");

        // A rejected/OOM model publication can arrive through the UI fallback.
        // Its newer snapshot must not be overwritten by the last accepted model.
        uint64_t ui_revision = cmdy_render_session_source_changed(t.session, environment());
        CmdyRenderSessionUpdate fresh = capture(&t); assert(fresh.source_revision == ui_revision);
        publish_ui(&t, fresh, layer, 261, 0xff0000);
        layer_pixels(device, layer->lastTexture, 255, 0, 0);
        assert(publish_model(&t, 262, 0x00ff00, false));
        (void)model_frame(&t); layer_pixels(device, layer->lastTexture, 0, 255, 0);
        puts("Model publication: newer UI fallback survives older native model and subsequent direct updates resume PASS");

        // The newest model can predate the UI capture callback's snapshot.
        cmdy_render_session_source_changed(t.session, environment());
        assert(publish_model(&t, 263, 0x0000ff, false));
        fresh = capture(&t);
        publish_ui(&t, fresh, layer, 262, 0xff0000);
        layer_pixels(device, layer->lastTexture, 0, 0, 255);
        puts("Model publication: worker overlays current model onto stale UI capture before submitting pixels PASS");

        atomic_store(&watch_completion, true);
        assert(publish_model(&t, 264, 0xff0000, false));
        assert(matching(&t, CMDY_SESSION_FRAME, 0).success); wait_for(completed);
        assert(publish_model(&t, 265, 0x0000ff, false));
        CmdyRenderSessionUpdate busy = inspect_layer(&t);
        assert(busy.inspection.frame_in_flight);
        dispatch_semaphore_signal(continue_completion);
        (void)model_frame(&t); layer_pixels(device, layer->lastTexture, 0, 0, 255);
        puts("Model publication: GPU backpressure recovers newest contents without a main-thread redraw PASS");

        unsigned committed_before = atomic_load(&commits);
        atomic_store(&pause_encode, true);
        assert(publish_model(&t, 266, 0xff0000, false)); wait_for(encoded);
        assert(publish_model(&t, 267, 0x00ff00, false));
        dispatch_semaphore_signal(continue_encode);
        (void)model_frame(&t); layer_pixels(device, layer->lastTexture, 0, 255, 0);
        assert(atomic_load(&commits) == committed_before + 1);
        puts("Model publication: a newer model arriving during encoding fences the obsolete GPU commit PASS");
        cmdy_render_session_close(t.session);
        assert(!publish_model(&t, 268, 0xff0000, true));
        assert(atomic_load(&payload_releases) == 257);
        cleanup(&t);
        puts("Model publication: close rejects late input and releases its retained payload exactly once PASS");
    }
    return 0;
}
