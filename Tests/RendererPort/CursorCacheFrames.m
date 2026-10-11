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
        for (unsigned scale=1;scale<=2;scale++) for(unsigned pattern=0;pattern<2;pattern++)
        for(unsigned mode=0;mode<4;mode++) for(unsigned style=0;style<=4;style+=2)
        for(unsigned column_index=0;column_index<3;column_index++) {
            @autoreleasepool {
                const unsigned columns_to_test[3]={0,2,3};
                CacheScene s={.scale=scale,.pattern=pattern,.mode=mode,.style=style,.column=columns_to_test[column_index],.done=dispatch_semaphore_create(0)};
                s.width=72*scale;s.height=60*scale;
                unsigned cursor_width=9*scale*(mode==0?1:2);
                unsigned cursor_x=s.column*cursor_width;
                s.crop_x=cursor_x>=2?cursor_x-2:0;s.crop_y=20*scale-2;
                s.tile_w=MIN(s.width,cursor_x+cursor_width+2)-s.crop_x;s.tile_h=20*scale+4;
                assert(s.crop_x+s.tile_w<=s.width && s.crop_y+s.tile_h<=s.height);
                NSArray<NSString *> *strings=pattern?@[@"🙂",@"e\u0301",@"가",@"█",@"─",@"A"]:@[@"A",@"é",@"i",@"W",@"g",@"Z",@"f",@" "];
                NSMutableArray *retained=[NSMutableArray array];CmdyRenderTextSegment segments[8]={0};
                intptr_t boundaries[8][2];unsigned col=0;
                for(unsigned i=0;i<strings.count;i++) {
                    unsigned columns=pattern && (i==0 || i==2)?2:1;
                    NSColor *ink=pattern?[NSColor colorWithSRGBRed:0.1+(i%3)*0.4 green:0.2+(i%4)*0.2 blue:0.8 alpha:0.3+(i%3)*0.3]:NSColor.whiteColor;
                    NSMutableDictionary *attrs=[@{NSFontAttributeName:font,NSForegroundColorAttributeName:ink} mutableCopy];
                    if(pattern) {attrs[NSBackgroundColorAttributeName]=[NSColor colorWithSRGBRed:0.15 green:0.06 blue:0.18 alpha:0.7];attrs[NSUnderlineStyleAttributeName]=@(NSUnderlineStyleSingle);}
                    NSAttributedString *text=[[NSAttributedString alloc] initWithString:strings[i] attributes:attrs];[retained addObject:text];
                    boundaries[i][0]=0;boundaries[i][1]=strings[i].length;
                    segments[i]=(CmdyRenderTextSegment){.attributed_string=(__bridge const void *)text,.column=col,.column_width=columns,
                        .character_count=1,.boundaries=boundaries[i],.boundary_count=2,.has_boundaries=1};col+=columns;
                }
                assert(col==8);
                s.input=(CmdyRenderRowInput){.segments=segments,.segment_count=strings.count,.cols=8,.width=s.width,.height=20*scale,
                    .cell_width=9*scale,.cell_height=20*scale,.scale=scale,.normal_font=(__bridge const void *)font,
                    .foreground=(__bridge const void *)NSColor.whiteColor,.coverage_exponent=1.35,.snaps_y=1,.antialias_blocks=1,
                    .ascii_caching=1,.font_caching=1,.underline_position=2*scale,.underline_thickness=scale};
                char base[64];snprintf(base,sizeof(base),"s%u-p%u-m%u-c%u-x%u",scale,pattern,mode,style,s.column);
                char path[4096];
                snprintf(path,sizeof(path),"%s/%s-full.bgra",argv[1],base);s.full_file=fopen(path,"wx");
                snprintf(path,sizeof(path),"%s/%s-crop.bgra",argv[1],base);s.reference_file=fopen(path,"wx");
                snprintf(path,sizeof(path),"%s/%s-tile.bgra",argv[1],base);s.candidate_file=fopen(path,"wx");
                snprintf(path,sizeof(path),"%s/%s-backing.bgra",argv[1],base);s.backing_file=fopen(path,"wx");
                assert(s.full_file && s.reference_file && s.candidate_file && s.backing_file);
                size_t n=s.tile_w*s.tile_h*4;s.reference=malloc(n);s.candidate=malloc(n);s.first=malloc(n);s.full=malloc(s.width*s.height*4);
                assert(s.reference && s.candidate && s.first && s.full);
                s.core.device=(__bridge const void *)device;s.core.worker=cmdy_render_worker_create_with_scope(pool);assert(s.core.worker);
                CmdyRenderOwnedRowInput *text=cmdy_render_input_capture(&s.input,NULL);assert(text);
                CmdyRenderFrameRowInput rows[3]={0};
                for(unsigned row=0;row<3;row++) {
                    rows[row]=(CmdyRenderFrameRowInput){.key={.absolute_row=row,.version=1,.cols=8,.width=s.width,.height=20*scale,.line_mode=mode,.font_name="Menlo"},
                        .font_name_bytes=5,.revision={1,1},.text=text,.placement={.display_index=row,.source_row=row,.line_mode=mode,
                        .has_selection=pattern && row==1,.selection_lower=1,.selection_upper=3}};
                }
                CmdyRenderFrameInput input={.identity={77,cmdy_render_worker_epoch(s.core.worker),1},.buffer_line_count=3,.rows=rows,.row_count=3,
                    .parameters={.width=s.width,.height=s.height,.scale=scale,.cell_width=9*scale,.cell_height=20*scale,.grid_rows=3,.grid_cols=8,
                        .cursor_source_row=1,.cursor_display_row=1,.cursor_col=s.column,.cursor_style=style,.cursor_valid=1,.caret_focused=1,
                        .cursor_natural_height=cmdy_render_cursor_font_height(20*scale,s.input.normal_font,scale),
                        .underline_thickness=1,.image_scale=1,.background={0.06,0.09,0.14,1},.selection={0.1,0.3,0.6,0.6},
                        .caret={0.2,0.8,0.5,1},.caret_text={0.9,0.1,0.3,1},.now=1}};
                s.input_frame=cmdy_render_frame_input_capture(&input,NULL);assert(s.input_frame);
                cmdy_render_input_release(text);
                invoke(&s.core,begin_cache);
                cmdy_render_frame_input_release(s.input_frame);s.input_frame=NULL;
                wait_for(s.done);invoke(&s.core,end_cache);assert(cmdy_render_worker_destroy(s.core.worker));
                assert(s.callbacks==1 && s.disposals==1);
                assert(cmdy_gpu_counter(0)==60);
                const CmdyRenderCursorFramesView *retained_frames=cmdy_render_cursor_frames_view(s.frames);
                assert(retained_frames && retained_frames->count==60 && retained_frames->bytes[3]==255);
                cmdy_render_cursor_frames_release(s.frames);s.frames=NULL;
                assert(s.index==60 && s.animated_pairs>0 && s.different_pairs==0);
                assert(fclose(s.full_file)==0 && fclose(s.reference_file)==0 && fclose(s.candidate_file)==0 && fclose(s.backing_file)==0);
                printf("{\"scene\":\"%s\",\"scale\":%u,\"pattern\":%u,\"lineMode\":%u,\"cursorStyle\":%u,\"cursorColumn\":%u,\"width\":%u,\"height\":%u,\"cropX\":%u,\"cropY\":%u,\"tileWidth\":%u,\"tileHeight\":%u,\"phasePairs\":60,\"maxChannelDifference\":%u,\"differentPairs\":%u,\"rejectedPairs\":%u,\"differentChannels\":%zu,\"animatedPairs\":%u,\"tints\":%zu,\"colorLayers\":%zu,\"workerDestroyed\":true}\n",base,scale,pattern,mode,style,s.column,s.width,s.height,s.crop_x,s.crop_y,s.tile_w,s.tile_h,s.max_diff,s.different_pairs,s.rejected_pairs,s.different_channels,s.animated_pairs,s.tint_count,s.color_count);fflush(stdout);
                free(s.reference);free(s.candidate);free(s.first);free(s.full);
            }
        }
        cmdy_gpu_shared_reset();assert(scope_depth==0 && NSApp==nil);
    }
    return 0;
}
