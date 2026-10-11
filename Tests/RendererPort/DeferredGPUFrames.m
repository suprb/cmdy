#define main gpu_owner_fixture_main
#include "GPUWorkerOwnership.m"
#undef main
#include "cmdy_render_frame_input.h"

enum { DW = 120, DH = 24, DB = DW * DH * 4 };
typedef struct DeferredGPU {
    Test core;
    CmdyRenderOwnedFrameInput *frame;
    CmdyRenderOwnedRowInput *text;
    dispatch_semaphore_t done;
    uint8_t reference[DB];
    unsigned phase;
} DeferredGPU;
static void frame_event(void *context,uint32_t kind) {
    DeferredGPU *t=context; owner(&t->core); assert(kind==1);
    uint8_t bytes[DB];
    [(__bridge id<MTLTexture>)t->core.texture getBytes:bytes bytesPerRow:DW*4
        fromRegion:MTLRegionMake2D(0,0,DW,DH) mipmapLevel:0];
    if (t->phase==0) {
        memcpy(t->reference,bytes,DB);
        for (unsigned col=4;col<=5;col++) {
            // Square Kitty images fit in the center of a 12x24 cell.
            const uint8_t *p=bytes+((DH/2)*DW+col*12+2)*4;
            assert(p[0]==0 && p[1]==0 && p[2]==255 && p[3]==255);
        }
        const uint8_t *p=bytes+(2*DW+7*12+2)*4;
        assert(p[0]==255 && p[1]==0 && p[2]==0 && p[3]==255);
    } else assert(memcmp(bytes,t->reference,DB)==0);
    dispatch_semaphore_signal(t->done);
}
static void setup_deferred_gpu(Test *core) {
    DeferredGPU *t=(DeferredGPU *)core; initialize(core);
    cmdy_gpu_set_event(core->gpu,frame_event,t);
    cmdy_gpu_apple_release(core->pass); cmdy_gpu_apple_release(core->texture);
    core->texture=cmdy_gpu_apple_texture(core->device,DW,DH,0,MTLPixelFormatBGRA8Unorm,1,0);
    core->pass=cmdy_gpu_apple_pass(core->texture); assert(core->texture && core->pass);
}
static void draw_deferred(Test *core) {
    DeferredGPU *t=(DeferredGPU *)core; owner(core);
    uint64_t rebuilt=cmdy_gpu_counter(1),reused=cmdy_gpu_counter(2);
    if (t->phase==1) assert(cmdy_render_input_view(t->text)==NULL);
    assert(cmdy_gpu_draw_captured(core->gpu,t->frame,NULL,core->pass));
    if (t->phase==1) assert(cmdy_render_input_view(t->text)!=NULL);
    if (t->phase==2) assert(cmdy_gpu_counter(1)==rebuilt && cmdy_gpu_counter(2)==reused+1);
}
static void reject_unprepared(Test *core) {
    DeferredGPU *t=(DeferredGPU *)core; owner(core);
    uint64_t rebuilt=cmdy_gpu_counter(1),reused=cmdy_gpu_counter(2);
    assert(cmdy_render_input_view(t->text)==NULL);
    assert(!cmdy_gpu_draw_captured(core->gpu,t->frame,NULL,core->pass));
    assert(cmdy_render_input_view(t->text)==NULL);
    assert(cmdy_gpu_counter(1)==rebuilt && cmdy_gpu_counter(2)==reused);
}
static void finish_deferred_gpu(Test *core) {
    owner(core); cmdy_gpu_destroy(core->gpu); core->gpu=NULL;
    release_targets(core); cmdy_render_worker_stop(core->worker);
}
int main(void) {
    @autoreleasepool {
        id<MTLDevice> device=MTLCreateSystemDefaultDevice(); assert(device);
        DeferredGPU t={.done=dispatch_semaphore_create(0)};
        t.core.device=(__bridge const void *)device;
        t.core.worker=cmdy_render_worker_create_with_scope(pool); assert(t.core.worker);
        invoke(&t.core,setup_deferred_gpu);
        NSFont *font=[NSFont fontWithName:@"Menlo" size:14]; assert(font);
        CmdyShapeStyleInput styleInput={0};
        for (unsigned i=0;i<4;i++) styleInput.fonts[i]=(__bridge const void *)font;
        for (unsigned i=0;i<5;i++) styleInput.colors[i]=(__bridge const void *)(i%2 ? NSColor.blackColor : NSColor.whiteColor);
        CmdyShapeStyle *style=cmdy_shape_style_create(&styleInput); assert(style);
        uint32_t status=99;
        CmdyRenderRowStyle *frozen=cmdy_render_row_style_capture(style,&status); assert(frozen && status==0);
        CmdyZigCell blank={.width=1}; CmdyZigLine *line=cmdy_zig_line_create(10,&blank,NULL,0,0); assert(line);
        const uint32_t scalars[]={'A',0x2500,0x2588};
        for (unsigned col=0;col<3;col++) { CmdyZigCell cell=blank; cell.scalar=scalars[col]; assert(!cmdy_zig_line_set(line,col,&cell,NULL,0,0)); }
        CmdyZigCell cell={.scalar=0x10eeee,.width=1,.fg=0x0200002a,.underline_present=1,.underline_color=0x02000009};
        uint32_t marks[]={0x305,0x305}; assert(!cmdy_zig_line_set(line,4,&cell,marks,2,1));
        CmdyRenderRowInput parameters={.cols=10,.width=DW,.height=DH,.cell_width=12,.cell_height=DH,.scale=1,
            .underline_position=2,.underline_thickness=1,.normal_font=(__bridge const void *)font,
            .foreground=(__bridge const void *)NSColor.whiteColor,.coverage_exponent=1.35,.snaps_y=1,.antialias_blocks=1,.ascii_caching=1,.font_caching=1};
        CmdyRenderOwnedRowInput *deferred=cmdy_render_input_capture_deferred(line,0,frozen,&parameters,&status);
        CmdyRenderOwnedRowInput *obsolete=cmdy_render_input_capture_deferred(line,0,frozen,&parameters,&status); assert(deferred && obsolete && status==0);
        CmdyShapeResult *shaped=cmdy_shape_line(line,0,style,0,0,0); assert(shaped);
        CmdyShapeView shape={0}; cmdy_shape_result_view(shaped,&shape); assert(shape.block_count==1 && shape.box_count==1 && shape.placeholder_count==1);
        const CmdyShapeBlock *block=&shape.blocks[0];
        CmdyRenderBlock mapped={.column=block->column,.column_width=block->column_width,.code_point=block->code_point,
            .rects=block->rects,.rect_count=block->rect_count,.foreground=block->foreground};
        CmdyRenderRowInput eagerInput=parameters; eagerInput.segments=shape.segments; eagerInput.segment_count=shape.segment_count;
        eagerInput.blocks=&mapped; eagerInput.block_count=1; eagerInput.boxes=shape.boxes; eagerInput.box_count=1;
        CmdyRenderOwnedRowInput *eager=cmdy_render_input_capture(&eagerInput,&status); assert(eager && status==0);
        CmdyGpuPlaceholder placeholders[2]={{.row=0,.col=5,.image_id=42,.placement_id=9},{.row=0,.col=4,.image_id=42,.placement_id=9}};
        uint8_t red[]={255,0,0,255},blue[]={0,0,255,255};
        CmdyRenderImageInput imageInput={.kind=1,.bytes=blue,.byte_count=4,.width=1,.height=1}; imageInput.identity[0]=7;
        CmdyRenderOwnedImageInput *image=cmdy_render_image_input_capture(&imageInput,&status); assert(image && status==0);
        CmdyRenderFrameImageInput imagePlacement={.payload=image,.placement={.col=7,.width=12,.height=12}};
        CmdyGpuKittyImage kitty={.image_id=42,.kind=1,.bytes=red,.byte_count=4,.width=1,.height=1};
        CmdyGpuKittyPlacement placement={.image_id=42,.placement_id=9,.cols=1,.rows=1}; uint32_t live=42;
        CmdyRenderFrameRowInput row={.key={.absolute_row=0,.version=77,.cols=10,.width=DW,.height=DH,.font_name="Menlo"},
            .font_name_bytes=5,.revision={77,7},.text=eager,.images=&imagePlacement,.image_count=1,.placeholders=placeholders,.placeholder_count=2};
        CmdyRenderFrameInput input={.identity={41,1,1},.rows=&row,.row_count=1,
            .parameters={.width=DW,.height=DH,.scale=1,.cell_width=12,.cell_height=DH,.grid_rows=1,.grid_cols=10,.image_scale=1,
                .cursor_hidden=1,.background={0,0,0,1},.now=1,.kitty_images=&kitty,.kitty_image_count=1,
                .kitty_placements=&placement,.kitty_placement_count=1,.live_kitty_ids=&live,.live_kitty_count=1}};
        CmdyRenderOwnedFrameInput *reference=cmdy_render_frame_input_capture(&input,&status); assert(reference && status==0);
        row.text=deferred; row.placeholder_count=1;
        CmdyRenderOwnedFrameInput *frame=cmdy_render_frame_input_capture(&input,&status); assert(frame && status==0);
        row.text=obsolete; input.identity.epoch=99;
        CmdyRenderOwnedFrameInput *stale=cmdy_render_frame_input_capture(&input,&status); assert(stale && status==0);
        assert(!cmdy_zig_line_reset(line,&blank,NULL,0,0,0)); cmdy_zig_line_release(line);
        cmdy_shape_result_free(shaped); cmdy_shape_style_free(style); cmdy_render_row_style_release(frozen);
        cmdy_render_input_release(eager); cmdy_render_image_input_release(image); memset(red,0,4); memset(blue,0,4);
        t.text=obsolete; t.frame=stale; invoke(&t.core,reject_unprepared);
        cmdy_render_frame_input_release(stale); cmdy_render_input_release(obsolete);
        t.phase=0; t.frame=reference; invoke(&t.core,draw_deferred); wait_for(t.done);
        cmdy_render_frame_input_release(reference);
        t.phase=1; t.text=deferred; t.frame=frame; invoke(&t.core,draw_deferred); wait_for(t.done);
        t.phase=2; invoke(&t.core,draw_deferred); wait_for(t.done);
        cmdy_render_frame_input_release(frame); cmdy_render_input_release(deferred);
        invoke(&t.core,finish_deferred_gpu); assert(cmdy_render_worker_destroy(t.core.worker)); cmdy_gpu_shared_reset();
        puts("Deferred GPU: supplied and decoded Kitty placeholders, ordinary RGBA, procedural glyph pixels, warm row reuse, source disposal and stale unprepared rejection PASS");
    }
    return 0;
}
