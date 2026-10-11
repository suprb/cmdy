// Reuse the existing raster comparator and run all legacy deferred-input checks.
// This is a headless fixture: no NSApplication, window, PTY or GPU target.
#define main legacyDeferredInputChecks
#include "DeferredRowInput.m"
#undef main

typedef struct SharedParameterWork {
    CmdyZigLine *line;
    CmdyRenderRowStyle *style;
    CmdyRenderRowParameters *parameters;
    CmdyRenderOwnedRowInput *lastRow;
    CmdyRenderRowRaster *raster;
} SharedParameterWork;

static void *captureSharedRows(void *raw) {
    @autoreleasepool {
        assert(!NSThread.isMainThread);
        SharedParameterWork *work=raw;
        for (int i=0;i<32;i++) {
            uint32_t status=999;
            CmdyRenderOwnedRowInput *row=cmdy_render_input_capture_frozen(
                work->line,100,work->style,work->parameters,&status);
            assert(row && status==CMDY_RENDER_INPUT_OK && cmdy_render_input_view(row)==NULL);
            const CmdyRenderRowInput *view=cmdy_render_input_prepare(row,&status);
            assert(view && status==CMDY_RENDER_INPUT_OK);
            assert(view->cols==8 && view->width==96 && view->height==20 && view->scale==1);
            NSColor *color=(__bridge NSColor *)view->foreground;
            assert(color.redComponent==1 && color.greenComponent==0 && color.blueComponent==0);
            if (i==31) {
                work->lastRow=row;
                work->raster=cmdy_render_row_create(view);
                assert(work->raster);
            } else { cmdy_render_input_release(row); }
        }
        cmdy_zig_line_release(work->line);
        cmdy_render_row_style_release(work->style);
        cmdy_render_row_parameters_release(work->parameters);
    }
    return NULL;
}

static void sharedParametersOwnAppearanceAcrossWorkers(void) {
    __block BOOL red=YES;
    __block unsigned resolutions=0;
    NSColor *foreground=[NSColor colorWithName:@"CmdySharedRowParameters" dynamicProvider:^NSColor *(NSAppearance *appearance) {
        (void)appearance;
        assert(NSThread.isMainThread);
        resolutions++;
        return red ? [NSColor colorWithDeviceRed:1 green:0 blue:0 alpha:1]
                   : [NSColor colorWithDeviceRed:0 green:0 blue:1 alpha:1];
    }];
    NSFont *font=[NSFont fontWithName:@"Menlo" size:14]; assert(font);
    CmdyShapeStyleInput styleInput={0};
    for (int i=0;i<4;i++) styleInput.fonts[i]=(__bridge const void *)font;
    for (int i=0;i<5;i++) styleInput.colors[i]=(__bridge const void *)(i%2 ? NSColor.blackColor : foreground);
    CmdyShapeStyle *style=cmdy_shape_style_create(&styleInput); assert(style);
    uint32_t status=999;
    CmdyRenderRowStyle *frozenStyle=cmdy_render_row_style_capture(style,&status);
    assert(frozenStyle && status==CMDY_RENDER_INPUT_OK);
    CmdyRenderRowInput input={.cols=8,.width=96,.height=20,.cell_width=12,.cell_height=20,.scale=1,
        .underline_position=2,.underline_thickness=1,.normal_font=(__bridge const void *)font,
        .foreground=(__bridge const void *)foreground,.coverage_exponent=1.35,.snaps_y=1,
        .antialias_blocks=1,.ascii_caching=1,.font_caching=1};
    CmdyRenderRowParameters *parameters=cmdy_render_row_parameters_capture(&input,&status);
    assert(parameters && status==CMDY_RENDER_INPUT_OK && resolutions>0);
    assert(cmdy_render_row_parameters_retain(parameters)==parameters);
    cmdy_render_row_parameters_release(parameters);

    CmdyZigCell blank={.width=1};
    CmdyZigLine *line=cmdy_zig_line_create(8,&blank,NULL,0,0); assert(line);
    uint32_t cluster[]={0x301};
    setCell(line,0,'A',1,1,cluster,1);
    setCell(line,1,0x1f600,2,0,NULL,0); setCell(line,2,0,0,0,NULL,0);
    setCell(line,4,0x2500,1,0,NULL,0); setCell(line,5,0x2588,1,0,NULL,0);
    CmdyZigLine *frozenLine=cmdy_zig_line_render_snapshot(line); assert(frozenLine);

    CmdyShapeResult *shaped=cmdy_shape_line(line,100,style,0,0,0); assert(shaped);
    CmdyShapeView shape={0}; cmdy_shape_result_view(shaped,&shape);
    CmdyRenderBlock *blocks=calloc(shape.block_count ?: 1,sizeof(*blocks)); assert(blocks);
    for (size_t i=0;i<shape.block_count;i++) {
        const CmdyShapeBlock *block=&shape.blocks[i];
        blocks[i]=(CmdyRenderBlock){.column=block->column,.column_width=block->column_width,
            .code_point=block->code_point,.rects=block->rects,.rect_count=block->rect_count,.foreground=block->foreground};
    }
    CmdyRenderRowInput eagerInput=input;
    eagerInput.segments=shape.segments; eagerInput.segment_count=shape.segment_count;
    eagerInput.blocks=blocks; eagerInput.block_count=shape.block_count;
    eagerInput.boxes=shape.boxes; eagerInput.box_count=shape.box_count;
    CmdyRenderOwnedRowInput *eager=cmdy_render_input_capture(&eagerInput,&status);
    assert(eager && status==CMDY_RENDER_INPUT_OK);
    CmdyRenderRowRaster *reference=cmdy_render_row_create(cmdy_render_input_view(eager)); assert(reference);

    assert(cmdy_render_row_parameters_capture(&eagerInput,&status)==NULL && status==CMDY_RENDER_INPUT_INVALID);
    CmdyRenderRowInput invalid=input; invalid.normal_font=NULL;
    assert(cmdy_render_row_parameters_capture(&invalid,&status)==NULL && status==CMDY_RENDER_INPUT_UNSUPPORTED_ATTRIBUTES);
    assert(cmdy_render_input_capture_frozen(NULL,100,frozenStyle,parameters,&status)==NULL && status==CMDY_RENDER_INPUT_INVALID);
    assert(cmdy_render_input_capture_frozen(frozenLine,100,NULL,parameters,&status)==NULL && status==CMDY_RENDER_INPUT_INVALID);
    assert(cmdy_render_input_capture_frozen(frozenLine,100,frozenStyle,NULL,&status)==NULL && status==CMDY_RENDER_INPUT_INVALID);

    SharedParameterWork work[8]={0};
    for (int i=0;i<8;i++) {
        work[i].line=cmdy_zig_line_retain(frozenLine);
        work[i].style=cmdy_render_row_style_retain(frozenStyle);
        work[i].parameters=cmdy_render_row_parameters_retain(parameters);
    }
    assert(cmdy_zig_line_reset(line,&blank,NULL,0,0,0)==0);
    cmdy_zig_line_release(line); cmdy_zig_line_release(frozenLine);
    cmdy_render_row_style_release(frozenStyle); cmdy_shape_style_free(style);
    cmdy_render_row_parameters_release(parameters);
    input.width=1; red=NO; foreground=nil; font=nil;
    const unsigned beforeWorkers=resolutions;
    pthread_t threads[8];
    for (int i=0;i<8;i++) assert(pthread_create(&threads[i],NULL,captureSharedRows,&work[i])==0);
    for (int i=0;i<8;i++) {
        assert(pthread_join(threads[i],NULL)==0);
        compareRasters(reference,work[i].raster);
        cmdy_render_row_free(work[i].raster);
        cmdy_render_input_release(work[i].lastRow);
    }
    assert(resolutions==beforeWorkers);
    cmdy_render_row_free(reference); cmdy_render_input_release(eager);
    free(blocks); cmdy_shape_result_free(shaped);
    assert(cmdy_render_row_parameters_capture(NULL,&status)==NULL && status==CMDY_RENDER_INPUT_INVALID);
    assert(cmdy_render_row_parameters_retain(NULL)==NULL);
    cmdy_render_row_parameters_release(NULL);
    puts("shared row parameters: 256 worker captures, eight exact raster comparisons, immutable appearance/lifetime and invalid-input checks PASS");
}

int main(void) {
    assert(legacyDeferredInputChecks()==0);
    @autoreleasepool { sharedParametersOwnAppearanceAcrossWorkers(); }
    return 0;
}
