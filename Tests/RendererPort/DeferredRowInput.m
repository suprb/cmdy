#import <AppKit/AppKit.h>
#include "cmdy_render_input.h"
#include "cmdy_render_worker.h"
#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void equalRect(CmdyRenderRect a, CmdyRenderRect b) {
    assert(a.x==b.x && a.y==b.y && a.width==b.width && a.height==b.height);
}
static void equalColor(CmdyRenderColor a, CmdyRenderColor b) {
    assert(a.r==b.r && a.g==b.g && a.b==b.b && a.a==b.a);
}
static void equalSolids(const CmdyRenderSolid *a, const CmdyRenderSolid *b, size_t count) {
    for (size_t i=0;i<count;i++) { equalRect(a[i].rect,b[i].rect); equalColor(a[i].color,b[i].color); }
}
static void compareRasters(CmdyRenderRowRaster *reference, CmdyRenderRowRaster *actualRaster) {
        CmdyRenderRowView expected = {0}, actual = {0};
        cmdy_render_row_view(reference,&expected);
        cmdy_render_row_view(actualRaster,&actual);
        assert(expected.width == actual.width && expected.height == actual.height);
        assert(expected.coverage_count > 0 && expected.coverage_count == actual.coverage_count);
        assert(memcmp(expected.coverage,actual.coverage,expected.coverage_count) == 0);
        assert(expected.glyph_count == actual.glyph_count && expected.tint_count == actual.tint_count);
        assert(expected.background_count == actual.background_count && expected.decoration_count == actual.decoration_count);
        equalSolids(expected.backgrounds,actual.backgrounds,expected.background_count);
        equalSolids(expected.decorations,actual.decorations,expected.decoration_count);
        for (size_t i=0;i<expected.tint_count;i++) {
            equalRect(expected.tints[i].rect,actual.tints[i].rect);
            equalRect(expected.tints[i].envelope,actual.tints[i].envelope);
            equalColor(expected.tints[i].color,actual.tints[i].color);
            assert(expected.tints[i].has_envelope==actual.tints[i].has_envelope);
            assert(expected.tints[i].replaced_by_atlas==actual.tints[i].replaced_by_atlas);
        }
        for (size_t i=0;i<expected.glyph_count;i++) {
            assert(expected.glyphs[i].glyph==actual.glyphs[i].glyph);
            assert(CFEqual(expected.glyphs[i].font,actual.glyphs[i].font));
            equalRect(expected.glyphs[i].rect,actual.glyphs[i].rect);
            equalColor(expected.glyphs[i].color,actual.glyphs[i].color);
        }
        assert(expected.color_tile_count==actual.color_tile_count);
        for (size_t i=0;i<expected.color_tile_count;i++) {
            const CmdyRenderColorTile *a=&expected.color_tiles[i], *b=&actual.color_tiles[i];
            assert(a->width==b->width && a->height==b->height && a->byte_count==b->byte_count);
            equalRect(a->rect,b->rect);
            assert(memcmp(a->bytes,b->bytes,a->byte_count)==0);
        }
}
typedef struct PrepareWork {
    CmdyRenderOwnedRowInput *input;
    const CmdyRenderRowInput *view;
    CmdyRenderRowRaster *raster;
    uint8_t expected_reuse;
} PrepareWork;
static dispatch_semaphore_t finished;
static void *racePrepare(void *value) {
    @autoreleasepool {
        assert(!NSThread.isMainThread);
        PrepareWork *work=value;
        for (int i=0;i<32;i++) {
            CmdyRenderOwnedRowInput *held=cmdy_render_input_retain(work->input);
            // Another preparer may publish between these two reads. A ready
            // view guarantees its classification; an unpublished view permits
            // only conservative false or that same final classification.
            const CmdyRenderRowInput *published=cmdy_render_input_view(held);
            uint8_t reuse=cmdy_render_input_revision_reusable(held);
            assert(published ? reuse==work->expected_reuse : (reuse==0 || reuse==work->expected_reuse));
            uint32_t status=999;
            const CmdyRenderRowInput *view=cmdy_render_input_prepare(held,&status);
            assert(view && status==CMDY_RENDER_INPUT_OK);
            assert(cmdy_render_input_revision_reusable(held)==work->expected_reuse);
            assert(!work->view || work->view==view);
            work->view=view;
            cmdy_render_input_release(held);
        }
    }
    return NULL;
}
static void workerPrepare(void *value,CmdyRenderWorker *worker,uint64_t epoch) {
    @autoreleasepool {
        assert(!NSThread.isMainThread && cmdy_render_worker_epoch(worker)==epoch);
        PrepareWork *work=value;
        assert(cmdy_render_input_view(work->input)==NULL);
        assert(cmdy_render_input_revision_reusable(work->input)==0);
        uint32_t status=999;
        work->view=cmdy_render_input_prepare(work->input,&status);
        assert(work->view && status==CMDY_RENDER_INPUT_OK);
        assert(cmdy_render_input_revision_reusable(work->input)==work->expected_reuse);
        work->raster=cmdy_render_row_create(work->view);
        assert(work->raster);
    }
}
static void disposed(void *value,uint32_t reason) {
    (void)value; assert(reason==CMDY_RENDER_WORKER_EXECUTED);
    dispatch_semaphore_signal(finished);
}
static void setCell(CmdyZigLine *line,int col,uint32_t scalar,int width,uint32_t style,const uint32_t *extras,size_t count) {
    CmdyZigCell cell={.scalar=scalar,.width=width,.style=style};
    if (style) { cell.fg=0x021acbe1; cell.bg=0x02281d5d; cell.underline_present=1; cell.underline_kind=1; cell.underline_color=0x02d252e1; }
    assert(cmdy_zig_line_set(line,col,&cell,extras,count,extras!=NULL)==0);
}
int main(void) {
    @autoreleasepool {
        for (int scene=0;scene<4;scene++) {
            __block BOOL bright=YES;
            NSColor *foreground=[NSColor colorWithName:@"CmdyDeferredOwnership" dynamicProvider:^NSColor *(NSAppearance *appearance) {
                (void)appearance; return bright ? NSColor.whiteColor : NSColor.blackColor;
            }];
            NSFont *font=[NSFont fontWithName:@"Menlo" size:14]; assert(font);
            CmdyShapeStyleInput styleInput={0};
            for (int i=0;i<4;i++) styleInput.fonts[i]=(__bridge const void *)font;
            for (int i=0;i<5;i++) styleInput.colors[i]=(__bridge const void *)(i%2 ? NSColor.blackColor : foreground);
            CmdyShapeStyle *style=cmdy_shape_style_create(&styleInput); assert(style);
            uint32_t status=999;
            CmdyRenderRowStyle *frozen=cmdy_render_row_style_capture(style,&status);
            assert(frozen && status==CMDY_RENDER_INPUT_OK);
            assert(cmdy_render_row_style_retain(frozen)==frozen); cmdy_render_row_style_release(frozen);
            CmdyZigCell blank={.width=1};
            CmdyZigLine *line=cmdy_zig_line_create(8,&blank,NULL,0,0); assert(line);
            setCell(line,0,'A',1,scene==1 ? 1 : 0,NULL,0);
            setCell(line,1,'z',1,0,NULL,0);
            if (scene>=2) {
                uint32_t cluster[]={0x301};
                setCell(line,0,0x41,1,0,cluster,1);
                setCell(line,1,0x1f600,2,0,NULL,0); setCell(line,2,0,0,0,NULL,0);
                setCell(line,4,0x2500,1,0,NULL,0); setCell(line,5,0x2588,1,0,NULL,0);
            }
            if (scene==3) {
                CmdyZigCell placeholder={.scalar=0x10eeee,.width=1,.fg=0x0200002a};
                uint32_t extras[]={0x305,0x305};
                assert(cmdy_zig_line_set(line,6,&placeholder,extras,2,1)==0);
            }
            CmdyRenderRowInput parameters={.cols=8,.width=96,.height=20,.cell_width=12,.cell_height=20,.scale=1,
                .underline_position=2,.underline_thickness=1,.normal_font=(__bridge const void *)font,
                .foreground=(__bridge const void *)foreground,.coverage_exponent=1.35,.snaps_y=1,
                .antialias_blocks=1,.ascii_caching=1,.font_caching=1};
            CmdyShapeResult *shaped=cmdy_shape_line(line,100,style,0,0,0); assert(shaped);
            CmdyShapeView shape={0}; cmdy_shape_result_view(shaped,&shape);
            CmdyRenderBlock *blocks=calloc(shape.block_count ?: 1,sizeof(*blocks)); assert(blocks);
            for (size_t i=0;i<shape.block_count;i++) {
                const CmdyShapeBlock *s=&shape.blocks[i];
                blocks[i]=(CmdyRenderBlock){.column=s->column,.column_width=s->column_width,
                    .code_point=s->code_point,.rects=s->rects,.rect_count=s->rect_count,.foreground=s->foreground};
            }
            CmdyRenderRowInput eagerInput=parameters;
            eagerInput.segments=shape.segments; eagerInput.segment_count=shape.segment_count;
            eagerInput.blocks=blocks; eagerInput.block_count=shape.block_count;
            eagerInput.boxes=shape.boxes; eagerInput.box_count=shape.box_count;
            CmdyRenderOwnedRowInput *eager=cmdy_render_input_capture(&eagerInput,&status);
            assert(eager && status==CMDY_RENDER_INPUT_OK);
            CmdyRenderRowRaster *reference=cmdy_render_row_create(cmdy_render_input_view(eager)); assert(reference);
            CmdyRenderOwnedRowInput *deferred=cmdy_render_input_capture_deferred(line,100,frozen,&parameters,&status);
            CmdyRenderOwnedRowInput *racing=cmdy_render_input_capture_deferred(line,100,frozen,&parameters,&status);
            assert(deferred && racing && status==CMDY_RENDER_INPUT_OK);
            assert(cmdy_render_input_view(deferred)==NULL && cmdy_render_input_view(racing)==NULL);
            assert(cmdy_render_input_revision_reusable(deferred)==0);
            assert(cmdy_render_input_revision_reusable(racing)==0);
            size_t count=999; assert(cmdy_render_input_placeholders(deferred,&count)==NULL && count==0);
            for (int i=0;i<64;i++) {
                CmdyRenderOwnedRowInput *cancelled=cmdy_render_input_capture_deferred(line,100,frozen,&parameters,&status);
                assert(cancelled && cmdy_render_input_view(cancelled)==NULL);
                assert(cmdy_render_input_revision_reusable(cancelled)==0);
                cmdy_render_input_release(cancelled);
            }
            assert(cmdy_render_input_capture_deferred(line,100,frozen,&eagerInput,&status)==NULL && status==CMDY_RENDER_INPUT_INVALID);
            CmdyRenderRowInput invalid=parameters; invalid.normal_font=NULL;
            assert(cmdy_render_input_capture_deferred(line,100,frozen,&invalid,&status)==NULL && status==CMDY_RENDER_INPUT_UNSUPPORTED_ATTRIBUTES);
            assert(cmdy_zig_line_reset(line,&blank,NULL,0,0,0)==0);
            cmdy_zig_line_release(line); cmdy_shape_style_free(style); cmdy_render_row_style_release(frozen);
            bright=NO; parameters.width=1; foreground=nil; font=nil;
            pthread_t threads[8]; PrepareWork work[8]={0};
            for (int i=0;i<8;i++) { work[i].input=racing; work[i].expected_reuse=(scene<2); assert(pthread_create(&threads[i],NULL,racePrepare,&work[i])==0); }
            for (int i=0;i<8;i++) { assert(pthread_join(threads[i],NULL)==0); assert(work[i].view==work[0].view); }
            PrepareWork owner={.input=deferred,.expected_reuse=(scene<2)};
            finished=dispatch_semaphore_create(0);
            CmdyRenderWorker *worker=cmdy_render_worker_create(); assert(worker);
            assert(cmdy_render_worker_submit(worker,cmdy_render_worker_epoch(worker),&owner,workerPrepare,disposed));
            assert(dispatch_semaphore_wait(finished,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC))==0);
            assert(cmdy_render_worker_destroy(worker));
            finished=nil;
            assert(owner.raster && owner.view==cmdy_render_input_view(deferred));
            compareRasters(reference,owner.raster);
            const CmdyShapePlaceholder *decoded=cmdy_render_input_placeholders(deferred,&count);
            assert(count==shape.placeholder_count);
            if (scene==3) assert(count==1 && decoded[0].image_id==42 && decoded[0].row==100 && decoded[0].col==6);
            for (size_t i=0;i<count;i++) {
                assert(decoded[i].row==shape.placeholders[i].row && decoded[i].col==shape.placeholders[i].col);
                assert(decoded[i].image_id==shape.placeholders[i].image_id && decoded[i].placement_id==shape.placeholders[i].placement_id);
                assert(decoded[i].placeholder_row==shape.placeholders[i].placeholder_row && decoded[i].placeholder_col==shape.placeholders[i].placeholder_col && decoded[i].msb==shape.placeholders[i].msb);
            }
            free(blocks); cmdy_shape_result_free(shaped);
            cmdy_render_input_release(eager); cmdy_render_input_release(deferred); cmdy_render_input_release(racing);
            cmdy_render_row_free(reference); cmdy_render_row_free(owner.raster);
        }
        uint32_t status=999;
        assert(cmdy_render_input_prepare(NULL,&status)==NULL && status==CMDY_RENDER_INPUT_INVALID);
        assert(cmdy_render_row_style_capture(NULL,&status)==NULL && status==CMDY_RENDER_INPUT_INVALID);
        cmdy_render_row_style_release(NULL);
        puts("deferred row: four scenes, immutable source/style lifetime, worker raster parity, concurrent first preparation, placeholders, unprepared release and invalid inputs PASS");
    }
    return 0;
}
