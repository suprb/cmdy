// Real pthread QoS and Metal session correctness; no app/window/input/benchmark.
#define main preceding_session_contract
#include "RendererSession.m"
#undef main
#include <pthread/qos.h>
#include <errno.h>

static atomic_uint priority_calls;
static atomic_bool reject_next_priority;
int32_t fixture_set_thread_qos_impl(uint8_t);
int32_t cmdy_gpu_apple_set_thread_qos(uint8_t priority) {
    assert(!pthread_main_np());
    atomic_fetch_add(&priority_calls, 1);
    if (atomic_exchange(&reject_next_priority, false)) return EPERM;
    return fixture_set_thread_qos_impl(priority);
}

static uint64_t request_number = 1000;
static void barrier(SessionTest *t) {
    uint64_t id = ++request_number;
    post(t, CMDY_SESSION_INSPECT, 0, id);
    (void)matching(t, CMDY_SESSION_INSPECTION, id);
}
static void expect_priority(SessionTest *t, qos_class_t expected) {
    barrier(t);
    qos_class_t actual = QOS_CLASS_UNSPECIFIED; int relative = 99;
    assert(pthread_get_qos_class_np(t->owner, &actual, &relative) == 0);
    assert(actual == expected && relative == 0);
}
static void surface(SessionTest *t, bool visible, bool key_window) {
    uint64_t id = ++request_number;
    CmdyRenderSessionCommand command = {.kind = CMDY_SESSION_EVENT,
        .event = CMDY_RENDER_UPDATE_ANIMATION, .request_id = id, .environment = environment()};
    command.environment.visible = visible;
    command.environment.key_window = key_window;
    assert(cmdy_render_session_post(t->session, &command));
    (void)matching(t, CMDY_SESSION_ACTIONS, id);
}
static void submit_focus(SessionTest *t, CmdyRenderFrameIdentity identity, bool focused) {
    CmdyRenderFrameInput input = {.identity = identity};
    input.parameters = (CmdyGpuFrame){.width = 8, .height = 8, .scale = 1, .cell_width = 8,
        .cell_height = 8, .grid_rows = 1, .grid_cols = 1, .cursor_hidden = 1,
        .caret_focused = focused, .image_scale = 1, .background = {1, 0, 0, 1}, .now = environment().now};
    uint32_t status = 99;
    CmdyRenderOwnedFrameInput *frame = cmdy_render_frame_input_capture(&input, &status); assert(frame && status == 0);
    CmdyRenderOwnedTarget *target = cmdy_render_target_capture(identity, NULL, t->pass, &status); assert(target && status == 0);
    // This environment intentionally carries the false focus placeholder.
    assert(cmdy_render_session_submit(t->session, frame, target, 0, environment()));
    cmdy_render_frame_input_release(frame); cmdy_render_target_release(target);
}
static void focus_frame(SessionTest *t, bool focused) {
    CmdyRenderSessionUpdate value = capture(t);
    submit_focus(t, value.identity, focused);
    assert(matching(t, CMDY_SESSION_FRAME, 0).success);
    gpu_done(t); pixels(t, 255, 0, 0);
}

int main(void) {
    @autoreleasepool {
        qos_class_t main_priority = qos_class_self();
        assert(fixture_set_thread_qos_impl(0) == EPERM);
        assert(fixture_set_thread_qos_impl(255) == EINVAL);
        assert(qos_class_self() == main_priority);
        id<MTLDevice> device = MTLCreateSystemDefaultDevice(); assert(device);
        SessionTest t; setup(&t, device); assert(matching(&t, CMDY_SESSION_READY, 0).success);
        expect_priority(&t, QOS_CLASS_USER_INTERACTIVE);
        surface(&t, true, true); expect_priority(&t, QOS_CLASS_USER_INITIATED);
        focus_frame(&t, true); expect_priority(&t, QOS_CLASS_USER_INTERACTIVE);
        puts("Worker QoS: foreground initialization, visible priority, accepted frame focus and exact pixels PASS");

        unsigned before = atomic_load(&priority_calls);
        for (unsigned i = 0; i < 100; i++) {
            uint64_t id = ++request_number;
            post(&t, CMDY_SESSION_EVENT, CMDY_RENDER_REQUEST, id);
            (void)matching(&t, CMDY_SESSION_ACTIONS, id);
        }
        expect_priority(&t, QOS_CLASS_USER_INTERACTIVE);
        assert(atomic_load(&priority_calls) == before);
        puts("Worker QoS: 100 focus-placeholder requests and inspection do not change priority or repeat syscalls PASS");

        surface(&t, false, true); expect_priority(&t, QOS_CLASS_UTILITY);
        surface(&t, true, false); expect_priority(&t, QOS_CLASS_USER_INITIATED);
        surface(&t, true, true); expect_priority(&t, QOS_CLASS_USER_INTERACTIVE);
        focus_frame(&t, false); expect_priority(&t, QOS_CLASS_USER_INITIATED);
        focus_frame(&t, true); expect_priority(&t, QOS_CLASS_USER_INTERACTIVE);
        puts("Worker QoS: hide/show, window deactivation and pane focus transitions PASS");

        // A frame may be accepted into the queue before a source invalidation
        // becomes visible. Its focus must be discarded with its stale pixels.
        CmdyRenderSessionUpdate old = capture(&t);
        post(&t, CMDY_SESSION_INSPECT, 0, 98); wait_for(t.blocked);
        before = atomic_load(&priority_calls);
        submit_focus(&t, old.identity, false);
        assert(cmdy_render_session_source_changed(t.session, environment()) != 0);
        dispatch_semaphore_signal(t.unblock);
        expect_priority(&t, QOS_CLASS_USER_INTERACTIVE);
        assert(atomic_load(&priority_calls) == before);
        puts("Worker QoS: obsolete queued frame cannot replace current focus PASS");

        // The host may hide a surface while a capture is pending. The later
        // packet's old visible environment must never raise its thread again.
        old = capture(&t);
        surface(&t, false, true);
        before = atomic_load(&priority_calls);
        submit_focus(&t, old.identity, true);
        assert(matching(&t, CMDY_SESSION_FRAME, 0).success); gpu_done(&t);
        expect_priority(&t, QOS_CLASS_UTILITY);
        assert(atomic_load(&priority_calls) == before);
        puts("Worker QoS: accepted packet cannot restore an older visible environment PASS");

        // An obsolete capture-failure acknowledgement is not a surface update.
        CmdyRenderSessionCommand failed = {.kind = CMDY_SESSION_CAPTURE_FAILED,
            .environment = environment(), .identity = old.identity};
        assert(cmdy_render_session_post(t.session, &failed));
        expect_priority(&t, QOS_CLASS_UTILITY);
        assert(atomic_load(&priority_calls) == before);
        puts("Worker QoS: obsolete capture-failure environment does not restore priority PASS");

        surface(&t, true, true); expect_priority(&t, QOS_CLASS_USER_INTERACTIVE);
        atomic_store(&reject_next_priority, true);
        before = atomic_load(&priority_calls);
        surface(&t, false, true); expect_priority(&t, QOS_CLASS_USER_INTERACTIVE);
        for (unsigned i = 0; i < 20; i++) surface(&t, false, true);
        assert(atomic_load(&priority_calls) == before + 1);
        surface(&t, true, false); expect_priority(&t, QOS_CLASS_USER_INITIATED);
        puts("Worker QoS: OS rejection preserves operation, avoids retry churn and retries the next class PASS");

        SessionTest other; setup(&other, device); assert(matching(&other, CMDY_SESSION_READY, 0).success);
        expect_priority(&other, QOS_CLASS_USER_INTERACTIVE);
        surface(&other, false, false); expect_priority(&other, QOS_CLASS_UTILITY);
        focus_frame(&other, true); expect_priority(&other, QOS_CLASS_USER_INTERACTIVE);
        expect_priority(&t, QOS_CLASS_USER_INITIATED);
        cleanup(&other); cleanup(&t);
        assert(qos_class_self() == main_priority);
        puts("Worker QoS: separate owner threads, main-thread protection and complete teardown PASS");
        printf("WORKER_QOS_PASS groups=8\n");
    }
    return 0;
}
