// Real Metal deadline behavior; no application, window, input, PTY or timing gate.
#define CMDY_SERVICE_CONTRACT_NAME existing_service_contract
#include "ServiceSession.m"

static void paced_draw(SessionTest *t, uint64_t request) {
    CmdyRenderSessionCommand command = {.kind = CMDY_SESSION_BEGIN_DRAW, .request_id = request,
        .environment = environment()};
    command.environment.key_window = false; command.environment.low_power = true;
    command.environment.thermal = 3;
    assert(cmdy_render_session_post(t->session, &command));
}

#ifndef CMDY_TIMED_CONTRACT_NAME
#define CMDY_TIMED_CONTRACT_NAME main
#endif
int CMDY_TIMED_CONTRACT_NAME(void) {
    assert(existing_service_contract() == 0);
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice(); assert(device);
        SessionTest t; start_layer(&t, device);
        CmdyRenderSessionUpdate first = capture(&t);
        LayerFixture *layer = layer_for(&t, device);
        publish_initial(&t, first, layer, NULL, (CmdyRenderColor){1, 0, 0, 1});
        request_service(&t, 901); (void)service_frame(&t);
        unsigned pacing_before = atomic_load(&owner_pacing_starts);
        for (unsigned i = 0; i < 12; i++) {
            paced_draw(&t, 910 + i); (void)native_timer_frame(&t);
            layer_pixels(device, layer->lastTexture, 255, 0, 0);
        }
        assert(atomic_load(&owner_pacing_starts) > pacing_before);
        assert(atomic_load(&layer->acquisitions) == 14);
        cleanup(&t);
        puts("Worker deadlines: twelve exact-pixel paced redraws without host timer, invalidation, service or capture PASS");

        start_layer(&t, device); first = capture(&t); layer = layer_for(&t, device);
        publish_initial(&t, first, layer, NULL, (CmdyRenderColor){0, 1, 0, 1});
        request_service(&t, 925); (void)service_frame(&t);
        pacing_before = atomic_load(&owner_pacing_starts);
        paced_draw(&t, 98); wait_for(t.blocked);
        (void)matching(&t, CMDY_SESSION_ACTIONS, 98);
        assert(atomic_load(&owner_pacing_starts) > pacing_before);
        CmdyRenderSessionCommand obsolete = {.kind = CMDY_SESSION_EVENT, .event = CMDY_RENDER_COALESCED_FIRED,
            .request_id = 926, .environment = environment()};
        obsolete.environment.visible = false;
        assert(cmdy_render_session_post(t.session, &obsolete));
        dispatch_semaphore_signal(t.unblock);
        CmdyRenderSessionUpdate ignored = matching(&t, CMDY_SESSION_ACTIONS, 926);
        assert(ignored.environment.visible && !ignored.actions.flags);
        (void)native_timer_frame(&t); layer_pixels(device, layer->lastTexture, 0, 255, 0);
        cleanup(&t);
        puts("Worker deadlines: a late host timer cannot consume owner pacing or restore its obsolete hidden environment PASS");

        start_layer(&t, device); first = capture(&t); layer = layer_for(&t, device);
        atomic_store(&intercept_feedback, true);
        publish_initial(&t, first, layer, NULL, (CmdyRenderColor){1, 0, 0, 1}); wait_for(feedback_registered);
        double after_deadline = environment().now + 0.09;
        deliver_failed_feedback(); (void)feedback_barrier(&t);
        CmdyRenderSessionCommand hidden = {.kind = CMDY_SESSION_EVENT, .event = CMDY_RENDER_UPDATE_ANIMATION,
            .request_id = 927, .environment = environment()};
        hidden.environment.visible = false; assert(cmdy_render_session_post(t.session, &hidden));
        (void)matching(&t, CMDY_SESSION_ACTIONS, 927);
        for (unsigned i = 0; i < 256; i++) {
            CmdyRenderSessionUpdate value = next(&t);
            assert(!value.environment.visible && value.kind != CMDY_SESSION_FRAME);
            if (value.environment.now >= after_deadline) break;
            assert(i != 255);
        }
        CmdyRenderSessionUpdate invisible = inspect_layer(&t);
        assert(!invisible.environment.visible && !invisible.inspection.drawing);
        assert(atomic_load(&layer->acquisitions) == 1);
        request_service(&t, 928); (void)service_frame(&t);
        layer_pixels(device, layer->lastTexture, 255, 0, 0); cleanup(&t);
        puts("Worker deadlines: recovery observes queued visibility changes and acquires nothing while hidden PASS");

        start_layer(&t, device); first = capture(&t); layer = layer_for(&t, device);
        atomic_store(&intercept_feedback, true);
        publish_initial(&t, first, layer, NULL, (CmdyRenderColor){1, 0, 0, 1}); wait_for(feedback_registered);
        deliver_failed_feedback(); (void)feedback_barrier(&t);
        uint64_t revision = cmdy_render_session_source_changed(t.session, environment());
        assert(revision == first.source_revision + 1);
        CmdyRenderSessionUpdate fresh = matching(&t, CMDY_SESSION_CAPTURE, 0);
        assert(fresh.source_revision == revision && atomic_load(&layer->acquisitions) == 1);
        publish_initial(&t, fresh, layer, NULL, (CmdyRenderColor){0, 0, 1, 1});
        layer_pixels(device, layer->lastTexture, 0, 0, 255); cleanup(&t);
        puts("Worker deadlines: recovery fences a changed source and requests fresh content before committing new pixels PASS");

        start_layer(&t, device); first = capture(&t); layer = layer_for(&t, device);
        atomic_store(&intercept_feedback, true);
        PublicationObservation observation = publication_observation(first);
        publish_initial(&t, first, layer, &observation, (CmdyRenderColor){1, 0, 0, 1}); wait_for(feedback_registered);
        deliver_failed_feedback(); (void)feedback_barrier(&t);
        unsigned before = atomic_load(&commits);
        cmdy_render_session_close(t.session); cleanup(&t); wait_for(observation.released);
        assert(atomic_load(&commits) == before && atomic_load(&layer->acquisitions) == 1);
        puts("Worker deadlines: close cancels recovery, releases owned content and joins without another GPU commit PASS");

        start_layer(&t, device); first = capture(&t); layer = layer_for(&t, device);
        publish_initial(&t, first, layer, NULL, (CmdyRenderColor){0, 1, 0, 1});
        // Park in the first keyboard reply so all later keys and the obsolete
        // host callback enter the FIFO before the worker can run its deadline.
        post(&t, CMDY_SESSION_EVENT, CMDY_RENDER_KEYBOARD, 98); wait_for(t.blocked);
        CmdyRenderSessionUpdate keyboard = matching(&t, CMDY_SESSION_ACTIONS, 98);
        assert(keyboard.inspection.has_feedback_deadline);
        assert(keyboard.actions.keyboard_interval > 0);
        assert(!(keyboard.actions.flags & CMDY_RENDER_START_KEYBOARD));
        assert(keyboard.actions.flags & CMDY_RENDER_STOP_KEYBOARD);
        for (unsigned i = 0; i < 5; i++) post(&t, CMDY_SESSION_EVENT, CMDY_RENDER_KEYBOARD, 940 + i);
        obsolete = (CmdyRenderSessionCommand){.kind = CMDY_SESSION_EVENT, .event = CMDY_RENDER_KEYBOARD_FIRED,
            .request_id = 945, .environment = environment()};
        obsolete.environment.visible = false;
        assert(cmdy_render_session_post(t.session, &obsolete));
        dispatch_semaphore_signal(t.unblock);
        for (unsigned i = 0; i < 5; i++) {
            CmdyRenderSessionUpdate repeated = matching(&t, CMDY_SESSION_ACTIONS, 940 + i);
            assert(repeated.inspection.has_feedback_deadline);
            assert(repeated.inspection.keyboard_feedback_deadline == keyboard.inspection.keyboard_feedback_deadline);
            assert(!(repeated.actions.flags & CMDY_RENDER_START_KEYBOARD));
        }
        ignored = matching(&t, CMDY_SESSION_ACTIONS, 945);
        assert(ignored.environment.visible && !ignored.actions.flags);
        (void)native_timer_frame(&t); layer_pixels(device, layer->lastTexture, 0, 255, 0);
        CmdyRenderSessionUpdate after_keyboard = inspect_layer(&t);
        assert(!after_keyboard.inspection.has_feedback_deadline);
        assert(atomic_load(&layer->acquisitions) == 2);
        cleanup(&t);
        puts("Worker keyboard: five queued keys preserve one deadline and exact pixels without a host timer, capture or stale visibility callback PASS");

        start_layer(&t, device); first = capture(&t); layer = layer_for(&t, device);
        publish_initial(&t, first, layer, NULL, (CmdyRenderColor){1, 0, 0, 1});
        post(&t, CMDY_SESSION_EVENT, CMDY_RENDER_KEYBOARD, 98); wait_for(t.blocked);
        keyboard = matching(&t, CMDY_SESSION_ACTIONS, 98);
        assert(!(keyboard.actions.flags & CMDY_RENDER_START_KEYBOARD));
        revision = cmdy_render_session_source_changed(t.session, environment());
        assert(revision == first.source_revision + 1);
        dispatch_semaphore_signal(t.unblock);
        fresh = matching(&t, CMDY_SESSION_CAPTURE, 0);
        assert(fresh.source_revision == revision && atomic_load(&layer->acquisitions) == 1);
        publish_initial(&t, fresh, layer, NULL, (CmdyRenderColor){0, 0, 1, 1});
        layer_pixels(device, layer->lastTexture, 0, 0, 255);
        cleanup(&t);
        puts("Worker keyboard: a source change fences old content before the feedback deadline can commit another frame PASS");

        start_layer(&t, device); first = capture(&t); layer = layer_for(&t, device);
        publish_initial(&t, first, layer, NULL, (CmdyRenderColor){1, 0, 0, 1});
        post(&t, CMDY_SESSION_EVENT, CMDY_RENDER_KEYBOARD, 98); wait_for(t.blocked);
        keyboard = matching(&t, CMDY_SESSION_ACTIONS, 98);
        assert(!(keyboard.actions.flags & CMDY_RENDER_START_KEYBOARD));
        hidden = (CmdyRenderSessionCommand){.kind = CMDY_SESSION_EVENT, .event = CMDY_RENDER_UPDATE_ANIMATION,
            .request_id = 946, .environment = environment()};
        hidden.environment.visible = false; assert(cmdy_render_session_post(t.session, &hidden));
        obsolete = (CmdyRenderSessionCommand){.kind = CMDY_SESSION_EVENT, .event = CMDY_RENDER_KEYBOARD_FIRED,
            .request_id = 947, .environment = environment()};
        assert(cmdy_render_session_post(t.session, &obsolete));
        dispatch_semaphore_signal(t.unblock);
        invisible = matching(&t, CMDY_SESSION_ACTIONS, 946);
        assert(!invisible.inspection.has_feedback_deadline && !invisible.environment.visible);
        ignored = matching(&t, CMDY_SESSION_ACTIONS, 947);
        assert(!ignored.environment.visible && !ignored.actions.flags);
        assert(atomic_load(&layer->acquisitions) == 1);
        cleanup(&t);
        puts("Worker keyboard: hidden-state cancellation rejects a late host callback and acquires no drawable PASS");

        start_layer(&t, device); first = capture(&t); layer = layer_for(&t, device);
        observation = publication_observation(first);
        publish_initial(&t, first, layer, &observation, (CmdyRenderColor){1, 0, 0, 1});
        before = atomic_load(&commits);
        post(&t, CMDY_SESSION_EVENT, CMDY_RENDER_KEYBOARD, 98); wait_for(t.blocked);
        keyboard = matching(&t, CMDY_SESSION_ACTIONS, 98);
        assert(!(keyboard.actions.flags & CMDY_RENDER_START_KEYBOARD));
        cmdy_render_session_close(t.session); dispatch_semaphore_signal(t.unblock);
        cleanup(&t); wait_for(observation.released);
        assert(atomic_load(&commits) == before && atomic_load(&layer->acquisitions) == 1);
        puts("Worker keyboard: close cancels the queued deadline and releases its publication without another commit PASS");
    }
    return 0;
}
