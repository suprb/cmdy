// Headless native session handoff. Presentation retirement is injected into
// the existing retained relay; this is not an on-screen transition claim.
#include "cmdy_render_session.h"
static void cursor_update_hook(void *,const CmdyRenderSessionUpdate *);
static CmdyRenderSession *cursor_session_factory(const void *,uint64_t,size_t,uint64_t,double,CmdyRenderSessionCallback,void *,CmdyRenderWorkerCallback);
#define CMDY_TEST_SESSION_UPDATE(context,value) cursor_update_hook(context,value)
#define cmdy_render_session_create cursor_session_factory
#define CMDY_MODEL_CONTRACT_NAME predecessor_model_contract
#include "ModelPublishedSession.m"
#undef cmdy_render_session_create
static dispatch_semaphore_t offered_signal;
static CmdyRenderCursorFrames *offered_frames;
static unsigned offers;
static void cursor_update_hook(void *context,const CmdyRenderSessionUpdate *value) {
    (void)context;
    if(value->kind==CMDY_SESSION_CURSOR_CACHE) {
        assert(value->cursor_frames && offered_frames==NULL);
        offered_frames=cmdy_render_cursor_frames_retain(value->cursor_frames);offers++;
        dispatch_semaphore_signal(offered_signal);
    }
}
static CmdyRenderSession *cursor_session_factory(const void *device,uint64_t format,size_t samples,uint64_t surface,double now,
    CmdyRenderSessionCallback callback,void *context,CmdyRenderWorkerCallback dispose) {
    return cmdy_render_session_create_with_options(device,format,samples,surface,now,CMDY_SESSION_CURSOR_CACHE_UPDATES,callback,context,dispose);
}
static CmdyRenderScheduleEnvironment focused_environment(void) {CmdyRenderScheduleEnvironment e=environment();e.caret_focused=true;return e;}
static void publish_cursor_ui(SessionTest *t, CmdyRenderSessionUpdate requested, CAMetalLayer *layer,
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
        .cell_height = 8, .grid_rows = 1, .grid_cols = 1, .cursor_hidden = 0, .cursor_style = 4, .cursor_valid = 1, .caret_focused = 1, .cursor_natural_height = 8, .caret = {1,0,1,1},
        .image_scale = 1, .background = {0, 0, 1, 1}, .now = environment().now};
    CmdyRenderOwnedFrameInput *frame = cmdy_render_frame_input_capture_viewport(&input, &viewport, NULL, NULL);
    assert(frame);
    assert(cmdy_render_session_publish_layer(t->session, frame, requested.source_revision,
        (__bridge const void *)layer, 1, focused_environment(), NULL, NULL, NULL));
    cmdy_render_frame_input_release(frame);
    cmdy_zig_buffer_snapshot_release(rows); cmdy_render_row_style_release(style);
    cmdy_render_row_parameters_release(parameters);
    assert(matching(t, CMDY_SESSION_FRAME, 0).success); gpu_done(t);
}

static void changed_cursor_model(SessionTest *t,uint64_t generation,uint32_t rgb) {
    CmdyZigBufferSnapshot *rows=model_rows(rgb,false);
    CmdyRenderModelInput input=model_input(rows,generation);input.cursor_hidden=0;input.cursor_style=4;
    assert(cmdy_render_session_publish_model(t->session,&input));cmdy_zig_buffer_snapshot_release(rows);
}
static void finish_presented(void) {
    assert(captured_feedback.callback && captured_feedback.dispose);
    captured_feedback.callback(captured_feedback.context,NSProcessInfo.processInfo.systemUptime);
    captured_feedback.dispose(captured_feedback.context);captured_feedback=(CapturedFeedback){0};
}
static CmdyRenderSessionUpdate cursor_offer(SessionTest *t) {
    // Cache eligibility starts after one second of idle. Callback count varies
    // with real GPU/presentation feedback and cannot be used as a clock.
    double started=NSProcessInfo.processInfo.systemUptime, deadline=started+5;
    unsigned callbacks=0;
    for (;;) {
        double remaining=deadline-NSProcessInfo.processInfo.systemUptime;
        assert(remaining>0);
        assert(dispatch_semaphore_wait(t->changed,dispatch_time(DISPATCH_TIME_NOW,(int64_t)(remaining*NSEC_PER_SEC)))==0);
        pthread_mutex_lock(&t->lock);assert(t->read<t->written);
        CmdyRenderSessionUpdate value=t->updates[t->read++ % 256];pthread_mutex_unlock(&t->lock);callbacks++;
        assert(value.kind!=CMDY_SESSION_ERROR && value.kind!=CMDY_SESSION_CAPTURE);
        if(value.kind==CMDY_SESSION_CURSOR_CACHE) {
            wait_for(offered_signal);
            fprintf(stderr,"offer after %.6fs and %u callbacks\n",NSProcessInfo.processInfo.systemUptime-started,callbacks);
            return value;
        }
    }
}

static void assert_blue_or_red(LayerFixture *layer,bool red) {
    uint8_t pixels[256];[layer->lastTexture getBytes:pixels bytesPerRow:32 fromRegion:MTLRegionMake2D(0,0,8,8) mipmapLevel:0];
    unsigned index=(7*8+7)*4;
    assert(pixels[index]==(red?0:255) && pixels[index+1]==0 && pixels[index+2]==(red?255:0) && pixels[index+3]==255);
}
int main(int argc,const char **argv) {
    (void)argv;assert(argc==2 && NSApp==nil);
    @autoreleasepool {
        id<MTLDevice> device=MTLCreateSystemDefaultDevice();assert(device);
        feedback_registered=dispatch_semaphore_create(0);
        for(unsigned scenario=0;scenario<6;scenario++) {
            offered_signal=dispatch_semaphore_create(0);offered_frames=NULL;offers=0;
            SessionTest t;setup(&t,device);assert(matching(&t,CMDY_SESSION_READY,0).success);
            LayerFixture *layer=layer_for(&t,device);
            CmdyRenderSessionUpdate initial=capture(&t);publish_cursor_ui(&t,initial,layer,1,0x0000ff);
            CmdyRenderSessionUpdate offer=cursor_offer(&t);assert(offers==1 && offered_frames);
            const CmdyRenderCursorFramesView *images=cmdy_render_cursor_frames_view(offered_frames);
            assert(images && images->count==60 && images->backing_byte_count==256 && images->backing_bytes[255]==255);
            uint64_t before=cmdy_gpu_counter(0);
            if(scenario==0) {
                assert(!cmdy_render_session_cursor_respond(t.session,offer.cursor_token+1,0));
                assert(cmdy_render_session_cursor_respond(t.session,offer.cursor_token,0));
                assert(!cmdy_render_session_cursor_respond(t.session,offer.cursor_token,0));
                worker_frame(&t);assert(cmdy_gpu_counter(0)>before);
            } else if(scenario==1) {
                assert(cmdy_render_session_cursor_respond(t.session,offer.cursor_token,1));worker_frame(&t);
                CmdyRenderSessionUpdate state=inspect_layer(&t);assert(state.inspection.animation_interval==0);
                before=cmdy_gpu_counter(0);usleep(80000);state=inspect_layer(&t);assert(cmdy_gpu_counter(0)==before);
                atomic_store(&intercept_feedback,true);changed_cursor_model(&t,2,0xff0000);
                worker_frame(&t);wait_for(feedback_registered);assert_blue_or_red(layer,true);
                finish_presented();CmdyRenderSessionUpdate retired=matching(&t,CMDY_SESSION_CURSOR_RETIRED,0);
                assert(retired.cursor_token==offer.cursor_token);cmdy_render_session_cursor_cancel(t.session,offer.cursor_token,1,0);
            } else if(scenario==2) {
                changed_cursor_model(&t,2,0xff0000);inspect_layer(&t);assert(cmdy_gpu_counter(0)==before);
                assert(cmdy_render_session_cursor_respond(t.session,offer.cursor_token,0));worker_frame(&t);assert_blue_or_red(layer,true);
            } else if(scenario==3) {
                cmdy_render_session_close(t.session);assert(!cmdy_render_session_cursor_respond(t.session,offer.cursor_token,1));
            } else if(scenario==4) {
                cmdy_render_session_cursor_cancel(t.session,0,1,0);
                assert(cmdy_render_session_cursor_generation(t.session)!=offer.cursor_generation);
                atomic_store(&intercept_feedback,true);
                assert(cmdy_render_session_cursor_respond(t.session,offer.cursor_token,1));worker_frame(&t);
                wait_for(feedback_registered);finish_presented();
                assert(matching(&t,CMDY_SESSION_CURSOR_RETIRED,0).cursor_token==offer.cursor_token);
                cmdy_render_session_cursor_cancel(t.session,offer.cursor_token,1,0);
            } else {
                assert(cmdy_render_session_invalidate(t.session,focused_environment())==offer.identity.epoch+1);
                inspect_layer(&t);assert(cmdy_gpu_counter(0)==before);
                assert(cmdy_render_session_cursor_respond(t.session,offer.cursor_token,0));
                CmdyRenderSessionUpdate next=matching(&t,CMDY_SESSION_CAPTURE,0);assert(next.identity.epoch==offer.identity.epoch+1);
            }
            cleanup(&t);
            images=cmdy_render_cursor_frames_view(offered_frames);assert(images && images->backing_bytes[255]==255);
            cmdy_render_cursor_frames_release(offered_frames);offered_frames=NULL;
            assert(!captured_feedback.callback);
            printf("{\"scenario\":%u,\"offers\":%u,\"sessionDestroyed\":true,\"retainedBackingAfterJoin\":true}\n",scenario,offers);fflush(stdout);
        }
        cmdy_gpu_shared_reset();assert(NSApp==nil);
    }
    return 0;
}
