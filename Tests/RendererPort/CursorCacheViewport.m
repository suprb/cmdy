// Real immutable frame cache compared with full native renders; no GUI.
#define main predecessor_ownership_main
#include "GPUWorkerOwnership.m"
#undef main
#include "cmdy_render_cursor_cache.h"
#include "cmdy_render_schedule.h"
#include <math.h>

typedef struct CacheScene {
    Test core;
    CmdyRenderRowInput input;
    CmdyRenderOwnedFrameInput *input_frame, *reference_frame;
    CmdyRenderCursorCache *job;
    CmdyRenderCursorFrames *frames;
    dispatch_semaphore_t done;
    unsigned scale, mode, pattern, style, column, index;
    unsigned width,height,crop_x,crop_y,tile_w,tile_h;
    unsigned max_diff,different_pairs,rejected_pairs,animated_pairs,callbacks,disposals;
    size_t different_channels,tint_count,color_count;
    uint8_t *reference,*candidate,*full,*first;
    FILE *full_file,*reference_file,*candidate_file,*backing_file;
} CacheScene;
static void submit_reference(CacheScene *s) {
    owner(&s->core);
    CmdyRenderFrameInput meta=*cmdy_render_frame_input_metadata(s->reference_frame);
    meta.parameters.now=1.0+s->index/50.0;
    CmdyRenderOwnedFrameInput *frame=cmdy_render_frame_input_reuse(s->reference_frame,&meta,NULL);assert(frame);
    assert(cmdy_gpu_draw_captured(s->core.gpu,frame,NULL,s->core.pass));
    cmdy_render_frame_input_release(frame);
}
static void reference_complete(void *context,uint32_t event) {
    CacheScene *s=context;owner(&s->core);assert(event==1);
    size_t n=s->tile_w*s->tile_h*4;
    [(__bridge id<MTLTexture>)s->core.texture getBytes:s->full bytesPerRow:s->width*4 fromRegion:MTLRegionMake2D(0,0,s->width,s->height) mipmapLevel:0];
    assert(fwrite(s->full,s->width*s->height*4,1,s->full_file)==1);
    for(unsigned y=0;y<s->tile_h;y++) memcpy(s->reference+y*s->tile_w*4,s->full+((y+s->crop_y)*s->width+s->crop_x)*4,s->tile_w*4);
    const CmdyRenderCursorFramesView *v=cmdy_render_cursor_frames_view(s->frames);assert(v);
    if(s->index==0 && v->backing_bytes) {
        assert(v->backing_width==s->width && v->backing_height==s->height && v->backing_byte_count==s->width*s->height*4);
        assert(memcmp(s->full,v->backing_bytes,v->backing_byte_count)==0);
        assert(fwrite(v->backing_bytes,v->backing_byte_count,1,s->backing_file)==1);
    }
    memcpy(s->candidate,v->bytes+s->index*n,n);
    assert(fwrite(s->reference,n,1,s->reference_file)==1 && fwrite(s->candidate,n,1,s->candidate_file)==1);
    if(s->index==0) memcpy(s->first,s->reference,n);
    else if(memcmp(s->first,s->reference,n))s->animated_pairs++;
    unsigned maximum=0;
    for(size_t i=0;i<n;i++) {unsigned d=(unsigned)abs((int)s->candidate[i]-(int)s->reference[i]);maximum=MAX(maximum,d);if(d)s->different_channels++;}
    if(maximum)s->different_pairs++;if(maximum>1)s->rejected_pairs++;s->max_diff=MAX(s->max_diff,maximum);
    if(++s->index==60){dispatch_semaphore_signal(s->done);return;}
    submit_reference(s);
}
static void cache_ready(void *context,uint32_t status,CmdyRenderCursorFrames *frames) {
    CacheScene *s=context;owner(&s->core);assert(status==CMDY_CURSOR_CACHE_READY && frames);s->callbacks++;
    assert(cmdy_gpu_counter(0)==0); // Offscreen phases are not terminal frames.
    s->frames=cmdy_render_cursor_frames_retain(frames);
    const CmdyRenderCursorFramesView *v=cmdy_render_cursor_frames_view(frames);
    assert(v->identity.surface==77 && v->identity.epoch==cmdy_render_worker_epoch(s->core.worker) && v->identity.sequence==1);
    assert(v->x==s->crop_x && v->y==s->crop_y && v->width==s->tile_w && v->height==s->tile_h);
    assert(v->scale==s->scale && v->viewport_width==s->width && v->viewport_height==s->height);
    assert(v->count==60 && v->bytes_per_frame==s->tile_w*s->tile_h*4 && v->activity_time==1 && v->active_until==13);
    cmdy_render_cursor_cache_release(s->job);s->job=NULL; // Reentrant caller release is safe.
    submit_reference(s);
}
static void cache_dispose(void *context) {CacheScene *s=context;owner(&s->core);s->disposals++;}
static void begin_cache(Test *core) {
    CacheScene *s=(CacheScene *)core;initialize(core);cmdy_gpu_rows_clear(core->gpu);
    cmdy_gpu_apple_release(core->texture);cmdy_gpu_apple_release(core->pass);
    core->texture=cmdy_gpu_apple_texture(core->device,s->width,s->height,0,MTLPixelFormatBGRA8Unorm,1,0);
    core->pass=cmdy_gpu_apple_pass(core->texture);assert(core->pass);
    CmdyRenderSchedule *schedule=cmdy_zig_gpu_schedule(core->gpu);
    CmdyRenderScheduleConfig config=cmdy_render_schedule_config(schedule);config.smooth_cursor=false;cmdy_render_schedule_set_config(schedule,config);
    cmdy_gpu_set_event(core->gpu,reference_complete,s);cmdy_gpu_counter_set(0,0);
    s->reference_frame=cmdy_render_frame_input_retain(s->input_frame);
    s->job=cmdy_render_cursor_cache_begin(core->worker,core->device,s->input_frame,0,1,13,cache_ready,s,cache_dispose);assert(s->job);
}
static void end_cache(Test *core) {
    CacheScene *s=(CacheScene *)core;owner(core);
    cmdy_render_frame_input_release(s->reference_frame);s->reference_frame=NULL;
    cmdy_gpu_destroy(core->gpu);core->gpu=NULL;release_targets(core);cmdy_render_worker_stop(core->worker);
}

int main(int argc,const char **argv) {
    assert(argc==2 && NSApp==nil);
    @autoreleasepool {
        id<MTLDevice> device=MTLCreateSystemDefaultDevice();assert(device);
        NSFont *font=[NSFont fontWithName:@"Menlo" size:14];assert(font);
        CmdyShapeStyleInput style_input={0};
        for(unsigned i=0;i<4;i++)style_input.fonts[i]=(__bridge const void *)font;
        for(unsigned i=0;i<5;i++)style_input.colors[i]=(__bridge const void *)NSColor.whiteColor;
        style_input.colors[1]=(__bridge const void *)NSColor.blackColor;
        CmdyShapeStyle *source_style=cmdy_shape_style_create(&style_input);assert(source_style);
        CmdyRenderRowStyle *row_style=cmdy_render_row_style_capture(source_style,NULL);assert(row_style);cmdy_shape_style_free(source_style);
        for(unsigned scale=1;scale<=2;scale++)for(unsigned geometry=0;geometry<2;geometry++)
        for(unsigned mode=0;mode<4;mode++)for(unsigned cursor=0;cursor<=4;cursor+=2)for(unsigned column_index=0;column_index<3;column_index++) {
            @autoreleasepool {
                const unsigned columns[]={0,2,3};
                CacheScene s={.scale=scale,.mode=mode,.pattern=geometry,.style=cursor,.column=columns[column_index],.done=dispatch_semaphore_create(0)};
                s.width=(72+8*geometry)*scale;s.height=(60+8*geometry)*scale;
                double content_x=geometry*3.25,top=geometry*2.25,bottom=geometry*2.75,left=geometry*1.25,scroll=geometry*3;
                unsigned cursor_width=9*scale*(mode?2:1);
                unsigned x=(unsigned)round(content_x*scale)+s.column*cursor_width;
                s.crop_x=MAX((unsigned)round(left*scale),x>=2?x-2:0);
                s.crop_y=(unsigned)ceil(top*scale)+20*scale-(unsigned)scroll-2;
                s.tile_w=MIN(s.width,x+cursor_width+2)-s.crop_x;s.tile_h=20*scale+4;
                s.input=(CmdyRenderRowInput){.cols=8,.width=s.width,.height=20*scale,.cell_width=9*scale,.cell_height=20*scale,.scale=scale,
                    .normal_font=(__bridge const void *)font,.foreground=(__bridge const void *)NSColor.whiteColor,.coverage_exponent=1.35,
                    .snaps_y=1,.antialias_blocks=1,.ascii_caching=1,.font_caching=1,.underline_position=2*scale,.underline_thickness=scale};
                CmdyRenderRowParameters *raster=cmdy_render_row_parameters_capture(&s.input,NULL);assert(raster);
                CmdyZigBuffer *buffer=cmdy_zig_buffer_create(8,3,0,0);assert(buffer);
                for(unsigned row=0;row<3;row++) {
                    CmdyZigLine *line=cmdy_zig_buffer_line(buffer,row);assert(line);
                    const uint32_t scalars[]={0x1f642,0,'e',0xac00,0,0x2588,0x2500,'A'};
                    for(unsigned col=0;col<8;col++) {
                        CmdyZigCell cell={.scalar=scalars[col],.width=(col==0 || col==3)?2:((col==1 || col==4)?0:1),
                            .fg=0x02000000 | (0x33aacc+col*0x170001),.bg=0x0233183d,.underline_kind=1};
                        const uint32_t accent=0x301;
                        assert(cmdy_zig_line_set(line,col,&cell,col==2?&accent:NULL,col==2?1:0,col==2?1:0)==0);
                    }
                    assert(cmdy_zig_line_set_metadata(line,2,mode)==0);cmdy_zig_line_release(line);
                }
                int32_t status=99;CmdyZigBufferSnapshot *snapshot=cmdy_zig_buffer_snapshot_capture(buffer,0,3,&status);assert(snapshot && status==0);
                s.core.worker=cmdy_render_worker_create_with_scope(pool);assert(s.core.worker);s.core.device=(__bridge const void *)device;
                CmdyRenderFrameInput input={.identity={77,cmdy_render_worker_epoch(s.core.worker),1},.buffer_line_count=3,
                    .parameters={.width=s.width,.height=s.height,.scale=scale,.cell_width=9*scale,.cell_height=20*scale,.grid_rows=3,.grid_cols=8,
                        .content_x=content_x,.top_inset=top,.bottom_inset=bottom,.left_inset=left,.scroll_pixels=scroll,
                        .cursor_source_row=1,.cursor_display_row=1,.cursor_col=s.column,.cursor_style=cursor,.cursor_valid=1,.caret_focused=1,
                        .cursor_natural_height=cmdy_render_cursor_font_height(20*scale,s.input.normal_font,scale),
                        .underline_thickness=1,.image_scale=1,.background={0.06,0.09,0.14,1},.selection={0.1,0.3,0.6,0.6},
                        .caret={0.2,0.8,0.5,1},.caret_text={0.9,0.1,0.3,1},.now=1}};
                CmdyRenderViewportInput viewport={.snapshot=snapshot,.style=row_style,.raster=raster,
                    .key={.cols=8,.width=s.width,.height=20*scale,.font_name="Menlo"},.font_name_bytes=5,
                    .has_selection=1,.selection_start_row=1,.selection_start_col=1,.selection_end_row=1,.selection_end_col=3};
                s.input_frame=cmdy_render_frame_input_capture_viewport(&input,&viewport,NULL,NULL);assert(s.input_frame);
                cmdy_zig_buffer_snapshot_release(snapshot);cmdy_zig_buffer_free(buffer);cmdy_render_row_parameters_release(raster);
                char name[64],path[4096];snprintf(name,sizeof(name),"s%u-g%u-m%u-c%u-x%u",scale,geometry,mode,cursor,s.column);
                snprintf(path,sizeof(path),"%s/%s-full.bgra",argv[1],name);s.full_file=fopen(path,"wx");
                snprintf(path,sizeof(path),"%s/%s-crop.bgra",argv[1],name);s.reference_file=fopen(path,"wx");
                snprintf(path,sizeof(path),"%s/%s-tile.bgra",argv[1],name);s.candidate_file=fopen(path,"wx");
                snprintf(path,sizeof(path),"%s/%s-backing.bgra",argv[1],name);s.backing_file=fopen(path,"wx");
                assert(s.full_file && s.reference_file && s.candidate_file && s.backing_file);
                size_t n=s.tile_w*s.tile_h*4;s.reference=malloc(n);s.candidate=malloc(n);s.first=malloc(n);s.full=malloc(s.width*s.height*4);
                assert(s.reference && s.candidate && s.first && s.full);
                invoke(&s.core,begin_cache);cmdy_render_frame_input_release(s.input_frame);s.input_frame=NULL;
                wait_for(s.done);invoke(&s.core,end_cache);assert(cmdy_render_worker_destroy(s.core.worker));
                assert(s.callbacks==1 && s.disposals==1 && cmdy_gpu_counter(0)==60 && s.index==60);
                const CmdyRenderCursorFramesView *v=cmdy_render_cursor_frames_view(s.frames);assert(v && v->bytes[3]==255);cmdy_render_cursor_frames_release(s.frames);
                assert(fclose(s.full_file)==0 && fclose(s.reference_file)==0 && fclose(s.candidate_file)==0 && fclose(s.backing_file)==0);
                printf("{\"scene\":\"%s\",\"scale\":%u,\"geometry\":%u,\"lineMode\":%u,\"cursorStyle\":%u,\"cursorColumn\":%u,\"width\":%u,\"height\":%u,\"cropX\":%u,\"cropY\":%u,\"tileWidth\":%u,\"tileHeight\":%u,\"phasePairs\":60,\"maxChannelDifference\":%u,\"differentPairs\":%u,\"animatedPairs\":%u,\"workerDestroyed\":true}\n",name,scale,geometry,mode,cursor,s.column,s.width,s.height,s.crop_x,s.crop_y,s.tile_w,s.tile_h,s.max_diff,s.different_pairs,s.animated_pairs);fflush(stdout);
                free(s.reference);free(s.candidate);free(s.first);free(s.full);
            }
        }
        cmdy_render_row_style_release(row_style);cmdy_gpu_shared_reset();assert(NSApp==nil && scope_depth==0);
    }
    return 0;
}
