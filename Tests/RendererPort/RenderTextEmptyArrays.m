#import <AppKit/AppKit.h>
#include "cmdy_render_text.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    @autoreleasepool {
        NSFont *font = [NSFont fontWithName:@"Menlo" size:14]; assert(font);
        CmdyRenderRowInput input = {.cols = 1, .width = 16, .height = 20,
            .cell_width = 16, .cell_height = 20, .scale = 1, .underline_thickness = 1,
            .normal_font = (__bridge const void *)font, .foreground = (__bridge const void *)NSColor.whiteColor};
        CmdyRenderRowRaster *row = cmdy_render_row_create(&input); assert(row);
        CmdyRenderRowView view = {0}; cmdy_render_row_view(row, &view);
        assert(view.coverage_count == 320);
        for (size_t i = 0; i < view.coverage_count; i++) assert(view.coverage[i] == 0);
        cmdy_render_row_free(row);
        CmdyRenderTextKey *key = cmdy_render_text_key_create(&input); assert(key); cmdy_render_text_key_free(key);
        intptr_t boundary = -1;
        assert(cmdy_render_text_boundaries(NULL, 0, &boundary, 1) == 1 && boundary == 0);
        assert(cmdy_render_text_boundaries(NULL, 1, &boundary, 1) == 0);
        input.segment_count = 1;
        assert(!cmdy_render_row_create(&input) && !cmdy_render_text_key_create(&input)); input.segment_count = 0;
        input.box_count = 1; assert(!cmdy_render_row_create(&input)); input.box_count = 0;
        input.block_count = 1; assert(!cmdy_render_row_create(&input));
        CmdyRenderBlock block = {.column_width = 1, .rect_count = 1, .foreground = input.foreground};
        input.blocks = &block; assert(!cmdy_render_row_create(&input));
        block.rect_count = 0; row = cmdy_render_row_create(&input); assert(row); cmdy_render_row_free(row);
        input.blocks = NULL; input.block_count = 0;
        NSAttributedString *text = [[NSAttributedString alloc] initWithString:@"A" attributes:@{NSFontAttributeName:font, NSForegroundColorAttributeName:NSColor.whiteColor}];
        CmdyRenderTextSegment segment = {.attributed_string = (__bridge const void *)text, .column_width = 1,
            .character_count = 1, .has_boundaries = 1, .boundary_count = 1};
        input.segments = &segment; input.segment_count = 1;
        assert(!cmdy_render_row_create(&input) && !cmdy_render_text_key_create(&input));
        segment.boundary_count = 0;
        key = cmdy_render_text_key_create(&input); assert(key); cmdy_render_text_key_free(key);
        input.segments = NULL; input.segment_count = SIZE_MAX;
        assert(!cmdy_render_row_create(&input) && !cmdy_render_text_key_create(&input));
        puts("text C arrays: null-empty row/key/boundaries and invalid nested counts PASS");
    }
    return 0;
}
