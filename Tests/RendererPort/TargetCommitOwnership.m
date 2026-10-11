#define main gpu_owner_fixture_main
#include "GPUWorkerOwnership.m"
#undef main
#include "cmdy_render_frame_input.h"
#include "cmdy_render_schedule.h"
#include <stdlib.h>

typedef struct TargetTest { Test core; } TargetTest;
static void target_event(void *context, uint32_t kind) {
    Test *t = context; owner(t); assert(kind == 1);
    t->frames++; dispatch_semaphore_signal(t->frames_done);
}
static void target_initialize(Test *t) {
    t->owner_thread = pthread_self(); owner(t); char error[2048] = {0};
    t->gpu = cmdy_gpu_create_on_worker(t->worker, t->device, MTLPixelFormatBGRA8Unorm, 1, 1, error, sizeof(error));
    assert(t->gpu); cmdy_gpu_set_event(t->gpu, target_event, t);
    t->texture = cmdy_gpu_apple_texture(t->device, 8, 8, 0, MTLPixelFormatBGRA8Unorm, 1, 0);
    t->pass = cmdy_gpu_apple_pass(t->texture); assert(t->texture && t->pass);
}
static TargetTest create_test(id<MTLDevice> device) {
    TargetTest t = {.core = {.device = (__bridge const void *)device, .frames_done = dispatch_semaphore_create(0)}};
    t.core.worker = cmdy_render_worker_create_with_scope(pool); assert(t.core.worker);
    // Moving this temporary before GPU event context is installed is required.
    return t;
}
static CmdyRenderOwnedFrameInput *make_frame(CmdyRenderFrameIdentity identity, CmdyRenderColor background, double width) {
    CmdyRenderFrameInput input = {.identity = identity};
    input.parameters = (CmdyGpuFrame){.width = width, .height = 8, .scale = 1, .cell_width = 8, .cell_height = 8,
        .grid_rows = 1, .grid_cols = 1, .cursor_hidden = 1, .image_scale = 1, .background = background, .now = 1};
    uint32_t status = 99; CmdyRenderOwnedFrameInput *frame = cmdy_render_frame_input_capture(&input, &status);
    assert(frame && status == CMDY_RENDER_INPUT_OK); return frame;
}
static CmdyRenderOwnedTarget *make_target(Test *t, CmdyRenderFrameIdentity identity) {
    uint32_t status = 99; CmdyRenderOwnedTarget *target = cmdy_render_target_capture(identity, NULL, t->pass, &status);
    assert(target && status == CMDY_RENDER_INPUT_OK); return target;
}
typedef struct Draw {
    Test *test;
    CmdyRenderOwnedFrameInput *frame;
    CmdyRenderOwnedTarget *target;
    dispatch_semaphore_t done;
    bool submitted;
} Draw;
static void draw_run(void *context, CmdyRenderWorker *worker, uint64_t epoch) {
    Draw *d = context; owner(d->test); assert(worker == d->test->worker && epoch != 0);
    d->submitted = cmdy_gpu_draw_target(d->test->gpu, d->frame, d->target);
}
static void draw_dispose(void *context, uint32_t reason) {
    Draw *d = context; assert(reason == CMDY_RENDER_WORKER_EXECUTED); dispatch_semaphore_signal(d->done);
}
static void enqueue(Draw *d) {
    d->done = dispatch_semaphore_create(0);
    assert(cmdy_render_worker_submit(d->test->worker, cmdy_render_frame_input_view(d->frame)->identity.epoch,
        d, draw_run, draw_dispose));
}
static bool draw_sync(Test *t, CmdyRenderOwnedFrameInput *frame, CmdyRenderOwnedTarget *target) {
    Draw d = {.test = t, .frame = frame, .target = target}; enqueue(&d); wait_for(d.done); return d.submitted;
}
static void color(Test *t, uint8_t r, uint8_t g, uint8_t b) {
    uint8_t bytes[8 * 8 * 4];
    [(__bridge id<MTLTexture>)t->texture getBytes:bytes bytesPerRow:8 * 4 fromRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0];
    for (unsigned i = 0; i < sizeof(bytes); i += 4) assert(bytes[i] == b && bytes[i + 1] == g && bytes[i + 2] == r && bytes[i + 3] == 255);
}
static void slot_empty(Test *t) {
    owner(t); assert(cmdy_render_worker_outstanding_completions(t->worker) == 1);
    CmdyRenderScheduleInspection state = cmdy_render_schedule_inspect(cmdy_zig_gpu_schedule(t->gpu));
    assert(!state.frame_in_flight);
}
static void shutdown_target_test(Test *t) {
    if (t->gpu) { cmdy_gpu_destroy(t->gpu); t->gpu = NULL; }
    cmdy_render_worker_stop(t->worker); assert(cmdy_render_worker_destroy(t->worker)); t->worker = NULL;
    cmdy_gpu_apple_release(t->pass); cmdy_gpu_apple_release(t->texture); t->pass = t->texture = NULL;
}

#ifdef CMDY_TARGET_INSTRUMENTED
static atomic_bool pause_encode, pause_commit, watch_completion;
static atomic_uint commit_count, ordering;
static unsigned commit_order;
static dispatch_semaphore_t encoded, continue_encode, committing, continue_commit, completed, continue_completion, delivered;
void fixture_encoder_end_impl(const void *encoder);
void fixture_commit_impl(const void *buffer,const void *drawable,CmdyGpuAppleCompletion fn,void *context);
void cmdy_gpu_apple_encoder_end(const void *encoder) {
    fixture_encoder_end_impl(encoder);
    if (atomic_exchange(&pause_encode, false)) { dispatch_semaphore_signal(encoded); wait_for(continue_encode); }
}
typedef struct CompletionBox { CmdyGpuAppleCompletion fn; void *context; bool watched; } CompletionBox;
static void wrapped_completion(void *context, double start, double end) {
    CompletionBox *box = context; bool watched = box->watched;
    if (watched) { dispatch_semaphore_signal(completed); wait_for(continue_completion); }
    box->fn(box->context, start, end); free(box);
    if (watched) dispatch_semaphore_signal(delivered);
}
void cmdy_gpu_apple_commit(const void *buffer,const void *drawable,CmdyGpuAppleCompletion fn,void *context) {
    if (atomic_exchange(&pause_commit, false)) { dispatch_semaphore_signal(committing); wait_for(continue_commit); }
    CompletionBox *box = malloc(sizeof(*box)); assert(box);
    *box = (CompletionBox){.fn = fn, .context = context, .watched = atomic_exchange(&watch_completion, false)};
    atomic_fetch_add(&commit_count, 1);
    fixture_commit_impl(buffer, drawable, wrapped_completion, box);
    commit_order = atomic_fetch_add(&ordering, 1) + 1;
}
typedef struct Invalidate {
    CmdyRenderWorker *worker;
    dispatch_semaphore_t started;
    uint64_t epoch;
    unsigned returned_order;
} Invalidate;
static void *invalidate_thread(void *context) {
    Invalidate *i = context; dispatch_semaphore_signal(i->started);
    i->epoch = cmdy_render_worker_invalidate(i->worker);
    i->returned_order = atomic_fetch_add(&ordering, 1) + 1; return NULL;
}
static void races(id<MTLDevice> device) {
    encoded = dispatch_semaphore_create(0); continue_encode = dispatch_semaphore_create(0);
    committing = dispatch_semaphore_create(0); continue_commit = dispatch_semaphore_create(0);
    completed = dispatch_semaphore_create(0); continue_completion = dispatch_semaphore_create(0); delivered = dispatch_semaphore_create(0);
    TargetTest first = create_test(device); Test *t = &first.core; invoke(t, target_initialize);
    CmdyRenderFrameIdentity old = {71, 1, 1};
    CmdyRenderOwnedFrameInput *old_frame = make_frame(old, (CmdyRenderColor){1, 0, 0, 1}, 8);
    CmdyRenderOwnedTarget *old_target = make_target(t, old);
    Draw before = {.test = t, .frame = old_frame, .target = old_target};
    unsigned initial_commits = atomic_load(&commit_count); atomic_store(&pause_encode, true); enqueue(&before); wait_for(encoded);
    uint64_t epoch = cmdy_render_worker_invalidate(t->worker); assert(epoch == 2);
    CmdyRenderFrameIdentity fresh = {72, epoch, 1};
    CmdyRenderOwnedFrameInput *new_frame = make_frame(fresh, (CmdyRenderColor){0, 0, 1, 1}, 8);
    CmdyRenderOwnedTarget *new_target = make_target(t, fresh);
    // Queue this before the aborted frame rolls back: it must get a free slot.
    Draw after = {.test = t, .frame = new_frame, .target = new_target}; enqueue(&after);
    dispatch_semaphore_signal(continue_encode); wait_for(before.done); wait_for(after.done); wait_for(t->frames_done);
    assert(!before.submitted && after.submitted && atomic_load(&commit_count) == initial_commits + 1);
    assert(t->frames == 1); color(t, 0, 0, 255); invoke(t, slot_empty);
    cmdy_render_target_release(old_target); cmdy_render_target_release(new_target);
    cmdy_render_frame_input_release(old_frame); cmdy_render_frame_input_release(new_frame);

    CmdyRenderFrameIdentity current = {72, epoch, 2};
    CmdyRenderOwnedFrameInput *frame = make_frame(current, (CmdyRenderColor){0, 1, 0, 1}, 8);
    CmdyRenderOwnedTarget *target = make_target(t, current);
    Draw inside = {.test = t, .frame = frame, .target = target};
    atomic_store(&ordering, 0); atomic_store(&pause_commit, true); atomic_store(&watch_completion, true);
    enqueue(&inside); wait_for(committing);
    Invalidate invalidation = {.worker = t->worker, .started = dispatch_semaphore_create(0)};
    pthread_t thread; assert(!pthread_create(&thread, NULL, invalidate_thread, &invalidation)); wait_for(invalidation.started);
    dispatch_semaphore_signal(continue_commit); wait_for(inside.done); assert(!pthread_join(thread, NULL));
    assert(inside.submitted && commit_order == 1 && invalidation.returned_order == 2 && invalidation.epoch == 3);
    wait_for(completed); dispatch_semaphore_signal(continue_completion); wait_for(delivered);
    invoke(t, slot_empty); assert(t->frames == 1); // Stale scoped completion is suppressed.
    color(t, 0, 255, 0); // Earlier submitted GPU work is not revoked by invalidate.
    cmdy_render_target_release(target); cmdy_render_frame_input_release(frame); shutdown_target_test(t);

    for (unsigned close_first = 0; close_first < 2; close_first++) {
        TargetTest stopping = create_test(device); t = &stopping.core; invoke(t, target_initialize);
        frame = make_frame(old, (CmdyRenderColor){1, 0, 0, 1}, 8); target = make_target(t, old);
        Draw interrupted = {.test = t, .frame = frame, .target = target};
        initial_commits = atomic_load(&commit_count); atomic_store(&pause_encode, true); enqueue(&interrupted); wait_for(encoded);
        if (close_first) { cmdy_gpu_destroy(t->gpu); t->gpu = NULL; }
        else cmdy_render_worker_stop(t->worker);
        dispatch_semaphore_signal(continue_encode); wait_for(interrupted.done);
        assert(!interrupted.submitted && atomic_load(&commit_count) == initial_commits && t->frames == 0);
        cmdy_render_target_release(target); cmdy_render_frame_input_release(frame); shutdown_target_test(t);
    }
    puts("Target commit races: invalidation during encoding, queued-frame rollback, commit ordering, stale completion, stop and close PASS");
}
#endif

int main(void) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice(); assert(device);
        TargetTest test = create_test(device); Test *t = &test.core; invoke(t, target_initialize);
        CmdyRenderFrameIdentity identity = {41, 1, 2}; uint32_t status = 99;
        assert(!cmdy_render_target_capture((CmdyRenderFrameIdentity){0, 1, 1}, NULL, t->pass, &status) && status == CMDY_RENDER_INPUT_INVALID);
        assert(!cmdy_render_target_capture(identity, NULL, NULL, &status));
        assert(!cmdy_render_target_capture(identity, NULL, (__bridge const void *)[MTLRenderPassDescriptor renderPassDescriptor], &status));
        assert(!cmdy_render_target_capture(identity, (__bridge const void *)[NSObject new], t->pass, &status));
        CmdyRenderOwnedFrameInput *frame = make_frame(identity, (CmdyRenderColor){1, 0, 0, 1}, 8);
        CmdyRenderOwnedTarget *target = make_target(t, identity);
        assert(cmdy_render_target_retain(target) == target); cmdy_render_target_release(target);
        // Mutating/releasing the producer descriptor cannot redirect the target.
        const void *other = cmdy_gpu_apple_texture(t->device, 8, 8, 0, MTLPixelFormatBGRA8Unorm, 1, 0);
        ((__bridge MTLRenderPassDescriptor *)t->pass).colorAttachments[0].texture = (__bridge id)other;
        cmdy_gpu_apple_release(other); cmdy_gpu_apple_release(t->pass); t->pass = cmdy_gpu_apple_pass(t->texture);
        CmdyRenderOwnedFrameInput *wrong = make_frame((CmdyRenderFrameIdentity){41, 1, 3}, (CmdyRenderColor){0, 1, 0, 1}, 8);
        assert(!draw_sync(t, wrong, target)); cmdy_render_frame_input_release(wrong);
        wrong = make_frame(identity, (CmdyRenderColor){0, 1, 0, 1}, 7);
        assert(!draw_sync(t, wrong, target)); cmdy_render_frame_input_release(wrong);
        assert(draw_sync(t, frame, target)); wait_for(t->frames_done); color(t, 255, 0, 0);
        assert(!draw_sync(t, frame, target)); cmdy_render_target_release(target);
        target = make_target(t, identity); assert(draw_sync(t, frame, target));
        cmdy_render_target_release(target); wait_for(t->frames_done); color(t, 255, 0, 0);
        for (unsigned foreign = 0; foreign < 2; foreign++) {
            CmdyRenderFrameIdentity rejected = {foreign ? 99 : 41, 1, 1};
            wrong = make_frame(rejected, (CmdyRenderColor){0, 0, 1, 1}, 8); target = make_target(t, rejected);
            assert(!draw_sync(t, wrong, target)); cmdy_render_target_release(target); cmdy_render_frame_input_release(wrong);
        }
        const void *rgba = cmdy_gpu_apple_texture(t->device, 8, 8, 0, MTLPixelFormatRGBA8Unorm, 1, 0);
        const void *rgba_pass = cmdy_gpu_apple_pass(rgba);
        target = cmdy_render_target_capture(identity, NULL, rgba_pass, &status); assert(target);
        assert(!draw_sync(t, frame, target)); cmdy_render_target_release(target);
        cmdy_gpu_apple_release(rgba_pass); cmdy_gpu_apple_release(rgba);
        cmdy_render_frame_input_release(frame); invoke(t, slot_empty); assert(t->frames == 2); shutdown_target_test(t);
        puts("Owned targets: descriptor copy, identity/geometry/format checks, single use, same-frame redraw, sequence/surface ordering and pixels PASS");
#ifdef CMDY_TARGET_INSTRUMENTED
        races(device);
#endif
        cmdy_gpu_shared_reset();
    }
    return 0;
}
