// Headless cancellation and bounded native ownership. No app/window/input.
#define main predecessor_ownership_main
#include "GPUWorkerOwnership.m"
#undef main
#include "cmdy_render_cursor_cache.h"
#include <math.h>

typedef struct Lifetime {
    Test core;
    CmdyRenderOwnedFrameInput *input;
    CmdyRenderCursorCache *job;
    CmdyRenderCursorFrames *frames;
    dispatch_semaphore_t done;
    unsigned mode,callbacks,disposals,result,capacity_disposals;
    CmdyRenderCompletion *tickets[1024];
    unsigned ticket_count;
} Lifetime;
static void ready(void *context,uint32_t result,CmdyRenderCursorFrames *frames) {
    Lifetime *s=context;owner(&s->core);s->callbacks++;s->result=result;
    assert(s->callbacks==1);
    if(result==CMDY_CURSOR_CACHE_READY) {assert(frames);s->frames=cmdy_render_cursor_frames_retain(frames);}
    else assert(!frames);
    if(s->mode==5) {cmdy_render_cursor_cache_cancel(s->job);cmdy_render_cursor_cache_release(s->job);s->job=NULL;}
}
static void disposed(void *context) {
    Lifetime *s=context;owner(&s->core);s->disposals++;assert(s->disposals==1);dispatch_semaphore_signal(s->done);
}
static void ticket_cancelled(void *context,CmdyRenderWorker *worker,uint32_t result) {
    Lifetime *s=context;owner(&s->core);assert(worker==s->core.worker && result==CMDY_RENDER_COMPLETION_CANCELLED);
}
static void ticket_disposed(void *context) {Lifetime *s=context;owner(&s->core);s->capacity_disposals++;}
static void begin_lifetime(Test *core) {
    Lifetime *s=(Lifetime *)core;core->owner_thread=pthread_self();owner(core);
    if(s->mode==6 || s->mode==7) {
        s->ticket_count=s->mode==6?1024:1023;
        for(unsigned i=0;i<s->ticket_count;i++) {
            s->tickets[i]=cmdy_render_worker_prepare_completion(core->worker,s,ticket_cancelled,ticket_disposed);assert(s->tickets[i]);
        }
    }
    s->job=cmdy_render_cursor_cache_begin(core->worker,core->device,s->input,0,1,13,ready,s,disposed);
    if(s->mode==6 || s->mode==7) {
        assert(!s->job && s->callbacks==0 && s->disposals==0);
        for(unsigned i=0;i<s->ticket_count;i++)cmdy_render_worker_cancel_completion(s->tickets[i]);
        return;
    }
    assert(s->job);
    if(s->mode==0 || s->mode==1) {
        if(s->mode==1)cmdy_render_cursor_cache_cancel(s->job);
        cmdy_render_cursor_cache_release(s->job);s->job=NULL;
    }
}
static void check_drained(Test *core) {
    Lifetime *s=(Lifetime *)core;owner(core);
    assert(cmdy_render_worker_outstanding_completions(core->worker)==0);
    assert(s->capacity_disposals==s->ticket_count);
}
static CmdyRenderOwnedFrameInput *capture_empty(CmdyRenderWorker *worker) {
    CmdyRenderFrameInput input={.identity={91,cmdy_render_worker_epoch(worker),1},.buffer_line_count=3,
        .parameters={.width=72,.height=60,.scale=1,.cell_width=9,.cell_height=20,.grid_rows=3,.grid_cols=8,
            .cursor_source_row=1,.cursor_display_row=1,.cursor_col=2,.cursor_style=0,.cursor_valid=1,.caret_focused=1,
            .cursor_natural_height=18,.underline_thickness=1,.image_scale=1,.background={0.06,0.09,0.14,1},
            .caret={0.2,0.8,0.5,1},.caret_text={0.9,0.1,0.3,1},.now=1}};
    return cmdy_render_frame_input_capture(&input,NULL);
}
static void rejection(Test *core) {
    Lifetime *s=(Lifetime *)core;core->owner_thread=pthread_self();owner(core);
    for(unsigned i=0;i<20;i++) {
        CmdyRenderFrameInput input=*cmdy_render_frame_input_metadata(s->input);
        double activity=1,until=13;unsigned preset=0;
        switch(i) {
            case 0:input.parameters.shader_mode=1;break;
            case 1:input.parameters.background.a=0.5;break;
            case 2:input.parameters.live_resize=1;break;
            case 3:input.parameters.cursor_hidden=1;break;
            case 4:input.parameters.host_cursor_hidden=1;break;
            case 5:input.parameters.caret_focused=0;break;
            case 6:input.parameters.cursor_valid=0;break;
            case 7:input.parameters.cursor_style=1;break;
            case 8:input.parameters.cursor_style=6;break;
            case 9:input.parameters.cursor_col=-1;break;
            case 10:input.parameters.cursor_display_row=3;break;
            case 11:input.parameters.width=NAN;break;
            case 12:input.parameters.cell_width=0;break;
            case 13:input.parameters.scale=17;break;
            case 14:input.parameters.content_x=INFINITY;break;
            case 15:input.parameters.width=10000;input.parameters.height=10000;input.parameters.cell_width=1000;input.parameters.cell_height=1000;break;
            case 16:activity=NAN;break;
            case 17:until=1.1;break;
            case 18:preset=6;break;
            case 19:input.identity.epoch++;break;
        }
        CmdyRenderOwnedFrameInput *frame=cmdy_render_frame_input_capture(&input,NULL);assert(frame);
        assert(!cmdy_render_cursor_cache_begin(core->worker,core->device,frame,preset,activity,until,ready,s,disposed));
        cmdy_render_frame_input_release(frame);
        assert(s->callbacks==0 && s->disposals==0 && cmdy_render_worker_outstanding_completions(core->worker)==0);
    }
}
int main(int argc,const char **argv) {
    (void)argv;assert(argc==2 && NSApp==nil);
    @autoreleasepool {
        id<MTLDevice> device=MTLCreateSystemDefaultDevice();assert(device);
        for(unsigned mode=0;mode<9;mode++) {
            Lifetime s={.mode=mode,.done=dispatch_semaphore_create(0)};
            s.core.device=(__bridge const void *)device;s.core.worker=cmdy_render_worker_create_with_scope(pool);assert(s.core.worker);
            s.input=capture_empty(s.core.worker);assert(s.input);cmdy_gpu_counter_set(0,0);
            if(mode==8) {
                assert(!cmdy_render_cursor_cache_begin(s.core.worker,s.core.device,s.input,0,1,13,ready,&s,disposed)); // Wrong owner.
                invoke(&s.core,rejection);cmdy_render_frame_input_release(s.input);s.input=NULL;
                cmdy_render_worker_stop(s.core.worker);assert(cmdy_render_worker_destroy(s.core.worker));
                printf("{\"case\":\"unsupported-and-wrong-owner\",\"rejections\":21,\"callbacks\":0,\"disposals\":0,\"workerDestroyed\":true}\n");continue;
            }
            // Hold the private renderer's real queue before admission, so
            // invalidation/stop/cross-thread cancel deterministically precede completion.
            char error[1024]={0};
            const void *raw=cmdy_gpu_shared_queue(s.core.device,MTLPixelFormatBGRA8Unorm,1,error,sizeof(error));assert(raw);
            id<MTLCommandQueue> queue=(__bridge id)raw;
            id<MTLSharedEvent> fence=[device newSharedEvent];assert(fence);
            id<MTLCommandBuffer> barrier=[queue commandBuffer];[barrier encodeWaitForEvent:fence value:1];[barrier commit];
            invoke(&s.core,begin_lifetime);cmdy_render_frame_input_release(s.input);s.input=NULL;
            if(mode==2)cmdy_render_cursor_cache_cancel(s.job);
            if(mode==3)assert(cmdy_render_worker_invalidate(s.core.worker)>1);
            if(mode==4)cmdy_render_worker_stop(s.core.worker);
            if(mode>=2 && mode<=4){cmdy_render_cursor_cache_release(s.job);s.job=NULL;}
            fence.signaledValue=1;
            if(mode<6) {
                wait_for(s.done);assert(s.callbacks==1 && s.disposals==1);
                assert(s.result==((mode==0 || mode==5)?CMDY_CURSOR_CACHE_READY:CMDY_CURSOR_CACHE_CANCELLED));
            } else {invoke(&s.core,check_drained);assert(s.callbacks==0 && s.disposals==0);}
            cmdy_render_worker_stop(s.core.worker);assert(cmdy_render_worker_destroy(s.core.worker));
            [barrier waitUntilCompleted];assert(barrier.status==MTLCommandBufferStatusCompleted);cmdy_gpu_apple_release(raw);
            assert(cmdy_gpu_counter(0)==0);
            if(s.frames) {
                const CmdyRenderCursorFramesView *v=cmdy_render_cursor_frames_view(s.frames);assert(v && v->count==60 && v->bytes[3]==255);
                cmdy_render_cursor_frames_release(s.frames);
            }
            printf("{\"case\":%u,\"callbacks\":%u,\"disposals\":%u,\"result\":%u,\"reservedCapacityDisposed\":%u,\"workerDestroyed\":true}\n",mode,s.callbacks,s.disposals,s.result,s.capacity_disposals);fflush(stdout);
        }
        cmdy_gpu_shared_reset();assert(NSApp==nil && scope_depth==0);
    }
    return 0;
}
