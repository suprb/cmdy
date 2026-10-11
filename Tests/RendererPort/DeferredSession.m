#define main original_session_fixture_main
#include "RendererSession.m"
#undef main

static CmdyRenderOwnedRowInput *unprepared_row(void) {
    @autoreleasepool {
        NSFont *font=[NSFont fontWithName:@"Menlo" size:8]; assert(font);
        CmdyShapeStyleInput input={0};
        for (unsigned i=0;i<4;i++) input.fonts[i]=(__bridge const void *)font;
        for (unsigned i=0;i<5;i++) input.colors[i]=(__bridge const void *)(i%2 ? NSColor.blackColor : NSColor.whiteColor);
        CmdyShapeStyle *style=cmdy_shape_style_create(&input); assert(style);
        uint32_t status=99;
        CmdyRenderRowStyle *frozen=cmdy_render_row_style_capture(style,&status); assert(frozen && status==0);
        CmdyZigCell cell={.scalar='A',.width=1}; CmdyZigLine *line=cmdy_zig_line_create(1,&cell,NULL,0,0); assert(line);
        CmdyRenderRowInput parameters={.cols=1,.width=8,.height=8,.cell_width=8,.cell_height=8,.scale=1,
            .normal_font=(__bridge const void *)font,.foreground=(__bridge const void *)NSColor.whiteColor,.coverage_exponent=1.35,.snaps_y=1};
        CmdyRenderOwnedRowInput *row=cmdy_render_input_capture_deferred(line,0,frozen,&parameters,&status); assert(row && status==0);
        cmdy_zig_line_release(line); cmdy_shape_style_free(style); cmdy_render_row_style_release(frozen);
        return row;
    }
}
static void submit_deferred(SessionTest *t,CmdyRenderFrameIdentity identity,CmdyRenderOwnedRowInput *text) {
    CmdyRenderFrameRowInput row={.key={.absolute_row=0,.version=1,.cols=1,.width=8,.height=8,.font_name="Menlo"},.font_name_bytes=5,.text=text};
    CmdyRenderFrameInput input={.identity=identity,.rows=&row,.row_count=1,
        .parameters={.width=8,.height=8,.scale=1,.cell_width=8,.cell_height=8,.grid_rows=1,.grid_cols=1,
            .cursor_hidden=1,.image_scale=1,.background={0,0,0,1},.now=environment().now}};
    uint32_t status=99;
    CmdyRenderOwnedFrameInput *frame=cmdy_render_frame_input_capture(&input,&status); assert(frame && status==0);
    CmdyRenderOwnedTarget *target=cmdy_render_target_capture(identity,NULL,t->pass,&status); assert(target && status==0);
    assert(cmdy_render_session_submit(t->session,frame,target,0,environment()));
    cmdy_render_frame_input_release(frame); cmdy_render_target_release(target);
}
int main(void) {
    @autoreleasepool {
        id<MTLDevice> device=MTLCreateSystemDefaultDevice(); assert(device);
        for (unsigned closing=0;closing<2;closing++) {
            SessionTest t; setup(&t,device); assert(matching(&t,CMDY_SESSION_READY,0).success);
            CmdyRenderSessionUpdate captured=capture(&t);
            post(&t,CMDY_SESSION_EVENT,CMDY_RENDER_RESET_PACING,98); wait_for(t.blocked);
            CmdyRenderOwnedRowInput *text=unprepared_row(); assert(cmdy_render_input_view(text)==NULL);
            uint64_t rebuilt=cmdy_gpu_counter(1);
            submit_deferred(&t,captured.identity,text);
            if (!closing) {
                assert(cmdy_render_session_invalidate(t.session,environment())==captured.identity.epoch+1);
                post(&t,CMDY_SESSION_INSPECT,0,101);
                dispatch_semaphore_signal(t.unblock);
                CmdyRenderSessionUpdate inspected=matching(&t,CMDY_SESSION_INSPECTION,101);
                assert(inspected.row_count==0 && cmdy_gpu_counter(1)==rebuilt);
                assert(cmdy_render_input_view(text)==NULL); cleanup(&t);
            } else {
                CmdyRenderSessionCommand command={.kind=CMDY_SESSION_EVENT,.event=CMDY_RENDER_RESET_PACING,.environment=environment()};
                unsigned accepted=0; while (accepted<2048 && cmdy_render_session_post(t.session,&command)) accepted++;
                assert(accepted>0 && accepted<1024);
                assert(!cmdy_render_session_invalidate(t.session,environment()));
                assert(cmdy_render_session_epoch(t.session)==captured.identity.epoch);
                cmdy_render_session_close(t.session); assert(cmdy_render_session_epoch(t.session)==0);
                dispatch_semaphore_signal(t.unblock); cleanup(&t);
                assert(cmdy_render_input_view(text)==NULL && cmdy_gpu_counter(1)==rebuilt);
            }
            cmdy_render_input_release(text);
        }
        puts("Deferred session: queued frame invalidation and reserved close under full queue discard unprepared rows; off-UI drain PASS");
    }
    return 0;
}
