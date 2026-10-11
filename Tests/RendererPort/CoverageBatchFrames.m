// Headless pixel and allocation-failure regression fixture. No windows, input or PTY.
#define main ownership_fixture_main
#include "GPUWorkerOwnership.m"
#undef main

static bool force_allocation_failure;
static atomic_bool fail_next_buffer;
static atomic_uint injected_failures;
static atomic_ulong draws, vertex_binds, writes, written_bytes, allocations, allocated_bytes;
extern void original_draw(const void *, size_t);
extern void original_vertex_buffer(const void *, const void *, size_t, size_t);
extern void original_buffer_write(const void *, size_t, const void *, size_t);
extern void *original_buffer(const void *, size_t);
void cmdy_gpu_apple_encoder_draw(const void *e, size_t n) {
    atomic_fetch_add(&draws, 1); original_draw(e, n);
}
void cmdy_gpu_apple_encoder_vertex_buffer(const void *e, const void *b, size_t o, size_t i) {
    atomic_fetch_add(&vertex_binds, 1); original_vertex_buffer(e, b, o, i);
}
void cmdy_gpu_apple_buffer_write(const void *b, size_t o, const void *p, size_t n) {
    atomic_fetch_add(&writes, 1); atomic_fetch_add(&written_bytes, n); original_buffer_write(b, o, p, n);
}
void *cmdy_gpu_apple_buffer(const void *device, size_t n) {
    if (atomic_exchange(&fail_next_buffer, false)) { atomic_fetch_add(&injected_failures, 1); return NULL; }
    atomic_fetch_add(&allocations, 1); atomic_fetch_add(&allocated_bytes, n); return original_buffer(device, n);
}

typedef struct Submission {
    Test core;
    CmdyRenderRowInput input;
    CmdyGpuFrameRow rows[4];
    size_t tint_count, atlas_count;
    unsigned cols, mode, pattern, frames, shader_mode;
    dispatch_semaphore_t done;
    uint8_t *pixels, *repeat;
} Submission;

static void submitted(void *context, uint32_t event) {
    Submission *s = context; owner(&s->core); assert(event == 1);
    size_t width = s->cols * 12, bytes = width * 80 * 4;
    uint8_t *p = s->frames == 0 ? s->pixels : s->repeat;
    [(__bridge id<MTLTexture>)s->core.texture getBytes:p bytesPerRow:width * 4
        fromRegion:MTLRegionMake2D(0, 0, width, 80) mipmapLevel:0];
    if (s->frames > 0) assert(memcmp(s->pixels, s->repeat, bytes) == 0);
    if (++s->frames < 4) { assert(cmdy_gpu_draw(s->core.gpu, &s->core.frame)); return; }
    dispatch_semaphore_signal(s->done);
}

static void begin_submission(Test *core) {
    Submission *s = (Submission *)core; initialize(core);
    cmdy_gpu_rows_clear(core->gpu);
    cmdy_gpu_apple_release(core->pass); cmdy_gpu_apple_release(core->texture);
    size_t width = s->cols * 12;
    core->texture = cmdy_gpu_apple_texture(core->device, width, 80, 0, MTLPixelFormatBGRA8Unorm, 1, 0);
    core->pass = cmdy_gpu_apple_pass(core->texture); assert(core->texture && core->pass);
    for (unsigned i = 0; i < 4; i++) {
        CmdyGpuRowKey key = {.absolute_row = i, .version = 1, .cols = s->cols,
            .line_mode = s->mode, .width = width, .height = 20, .font_name = "Menlo"};
        s->rows[i] = (CmdyGpuFrameRow){.display_index = i, .source_row = i, .line_mode = s->mode};
        s->rows[i].entry = cmdy_gpu_row_resolve(core->gpu, &key, (CmdyGpuRowRevision){1,1}, &s->input, NULL, 0, NULL, 0);
        assert(s->rows[i].entry);
        CmdyGpuRowView view; cmdy_gpu_row_view(s->rows[i].entry, &view);
        s->tint_count += view.tint_count; s->atlas_count += view.atlas_glyph_count;
    }
    core->frame = (CmdyGpuFrame){.pass = core->pass, .rows = s->rows, .row_count = 4,
        .width = width, .height = 80, .scale = 1, .cell_width = 12, .cell_height = 20,
        .grid_rows = 4, .grid_cols = s->cols, .cursor_hidden = 1, .image_scale = 1,
        .background = {0,0,0,1}, .now = 1, .shader_mode = s->shader_mode, .shader_energy = 0.65, .shader_velocity = 3.5};
    cmdy_gpu_set_event(core->gpu, submitted, s);
    atomic_store(&draws, 0); atomic_store(&vertex_binds, 0); atomic_store(&writes, 0);
    atomic_store(&written_bytes, 0); atomic_store(&allocations, 0); atomic_store(&allocated_bytes, 0);
    atomic_store(&fail_next_buffer, force_allocation_failure);
    assert(cmdy_gpu_draw(core->gpu, &core->frame));
}
static void end_submission(Test *core) {
    owner(core); cmdy_gpu_destroy(core->gpu); core->gpu = NULL;
    release_targets(core); cmdy_render_worker_stop(core->worker);
}
int main(int argc, const char **argv) {
    assert(argc == 4); unsigned shader_mode = (unsigned)strtoul(argv[2], NULL, 10);
    assert(shader_mode == 0 || shader_mode == 1 || shader_mode == 68);
    force_allocation_failure = strcmp(argv[3], "fail-first-buffer") == 0;
    assert(force_allocation_failure || strcmp(argv[3], "normal") == 0);
    FILE *images = fopen(argv[1], "wx"); assert(images);
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice(); assert(device);
        NSFont *font = [NSFont fontWithName:@"Menlo" size:14]; assert(font);
        const unsigned counts[] = {1, 63, 64, 65, 120, 257};
        for (unsigned pattern = 0; pattern < 2; pattern++) for (unsigned mode = 0; mode < 4; mode++)
        for (unsigned c = 0; c < sizeof(counts) / sizeof(counts[0]); c++) {
            unsigned cols = counts[c];
            NSMutableString *string = [NSMutableString string];
            intptr_t boundaries[258];
            for (unsigned i = 0; i < cols; i++) { [string appendFormat:@"%c", 'A' + i % 26]; boundaries[i] = i; }
            boundaries[cols] = cols;
            NSMutableAttributedString *text = [[NSMutableAttributedString alloc] initWithString:string
                attributes:@{NSFontAttributeName:font, NSForegroundColorAttributeName:NSColor.whiteColor}];
            if (pattern) for (unsigned i = 0; i < cols; i++) {
                NSColor *color = [NSColor colorWithSRGBRed:(i % 3) * 0.4 + 0.1 green:(i % 5) * 0.2
                    blue:0.8 alpha:0.3 + (i % 3) * 0.3];
                [text addAttribute:NSForegroundColorAttributeName value:color range:NSMakeRange(i, 1)];
            }
            CmdyRenderTextSegment segment = {.attributed_string = (__bridge const void *)text, .column_width = 1,
                .character_count = cols, .boundaries = boundaries, .boundary_count = cols + 1, .has_boundaries = 1};
            Submission s = {.cols = cols, .mode = mode, .pattern = pattern, .shader_mode = shader_mode, .done = dispatch_semaphore_create(0)};
            s.input = (CmdyRenderRowInput){.segments = &segment, .segment_count = 1, .cols = cols, .width = cols * 12,
                .height = 20, .cell_width = 12, .cell_height = 20, .scale = 1,
                .normal_font = (__bridge const void *)font, .foreground = (__bridge const void *)NSColor.whiteColor,
                .coverage_exponent = 1.35, .snaps_y = 1, .ascii_caching = 1, .font_caching = 1};
            size_t bytes = cols * 12 * 80 * 4;
            s.pixels = calloc(bytes, 1); s.repeat = calloc(bytes, 1); assert(s.pixels && s.repeat);
            s.core.device = (__bridge const void *)device;
            s.core.worker = cmdy_render_worker_create_with_scope(pool); assert(s.core.worker);
            invoke(&s.core, begin_submission); wait_for(s.done);
            unsigned long calls = atomic_load(&draws), binds = atomic_load(&vertex_binds), uploads = atomic_load(&writes);
            assert(s.frames == 4 && binds == uploads);
            bool painted = false;
            for (size_t i = 0; i < bytes; i += 4) if (s.pixels[i] || s.pixels[i+1] || s.pixels[i+2]) { painted = true; break; }
            assert(painted && fwrite(s.pixels, bytes, 1, images) == 1);
            printf("{\"cols\":%u,\"line_mode\":%u,\"pattern\":%u,\"rows\":4,\"frames\":4,\"tints\":%zu,\"atlas_glyphs\":%zu,\"draws_total\":%lu,\"vertex_binds_total\":%lu,\"uploads_total\":%lu,\"uploaded_bytes_total\":%lu,\"buffer_allocations\":%lu,\"buffer_requested_bytes\":%lu}\n",
                cols, mode, pattern, s.tint_count, s.atlas_count, calls, binds, uploads,
                atomic_load(&written_bytes), atomic_load(&allocations), atomic_load(&allocated_bytes));
            invoke(&s.core, end_submission); assert(cmdy_render_worker_destroy(s.core.worker));
            free(s.pixels); free(s.repeat);
        }
        assert(atomic_load(&injected_failures) == (force_allocation_failure ? 48u : 0u));
        cmdy_gpu_shared_reset();
    }
    assert(fclose(images) == 0); return 0;
}
