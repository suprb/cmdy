#ifndef CMDY_RENDER_SHAPE_H
#define CMDY_RENDER_SHAPE_H
#include <stddef.h>
#include <stdint.h>
#include "cmdy_buffer.h"
#include "cmdy_render_text.h"
#ifdef __cplusplus
extern "C" {
#endif
typedef struct CmdyShapeStyle CmdyShapeStyle;
typedef struct CmdyShapeContext CmdyShapeContext;
typedef struct CmdyShapeResult CmdyShapeResult;
typedef struct CmdyShapeStyleInput {
 const void *const *palette; size_t palette_count;
 const void *fonts[4];
 const void *colors[5]; /* foreground, background, selection, failed fore/back */
 const intptr_t *failed_rows; size_t failed_row_count;
} CmdyShapeStyleInput;
CmdyShapeStyle *cmdy_shape_style_create(const CmdyShapeStyleInput *);
CmdyShapeStyle *cmdy_shape_style_retain(CmdyShapeStyle *);
void cmdy_shape_style_free(CmdyShapeStyle *);
uint8_t cmdy_shape_style_equal(const CmdyShapeStyle *,const CmdyShapeStyle *);
const void *cmdy_shape_style_object(const CmdyShapeStyle *,uint8_t group,size_t index);
size_t cmdy_shape_style_count(const CmdyShapeStyle *,uint8_t group);
const intptr_t *cmdy_shape_style_failed_rows(const CmdyShapeStyle *);
CmdyShapeContext *cmdy_shape_context_create(void);
void cmdy_shape_context_free(CmdyShapeContext *);
void cmdy_shape_context_begin(CmdyShapeContext *);
/* Borrowed style; context retains the frame. Set resolves under caller's appearance. */
CmdyShapeStyle *cmdy_shape_context_style(CmdyShapeContext *);
CmdyShapeStyle *cmdy_shape_context_set(CmdyShapeContext *,CmdyShapeStyle *);
uint8_t cmdy_shape_context_revision(const CmdyShapeContext *,uint64_t version,uint8_t has_images,uint64_t *out);
typedef struct CmdyShapeBlock {
 intptr_t column,column_width; uint32_t code_point;
 CmdyRenderBlockRect rects[3]; size_t rect_count; const void *foreground;
} CmdyShapeBlock;
typedef struct CmdyShapePlaceholder { intptr_t row,col; uint32_t image_id,placement_id; intptr_t placeholder_row,placeholder_col,msb; } CmdyShapePlaceholder;
typedef struct CmdyShapeView {
 const CmdyRenderTextSegment *segments; size_t segment_count;
 const CmdyShapeBlock *blocks; size_t block_count;
 const CmdyRenderBox *boxes; size_t box_count;
 const CmdyShapePlaceholder *placeholders; size_t placeholder_count;
 intptr_t represented_columns;
} CmdyShapeView;
CmdyShapeResult *cmdy_shape_line(const CmdyZigLine *,intptr_t row,const CmdyShapeStyle *,uint8_t selected,intptr_t lower,intptr_t upper);
void cmdy_shape_result_free(CmdyShapeResult *);
void cmdy_shape_result_view(const CmdyShapeResult *,CmdyShapeView *);
/* +1 retained Objective-C values for the host facade. */
const void *cmdy_shape_cursor(const CmdyZigLine *,intptr_t column,const CmdyShapeStyle *,const void *caret,const void *text);
const void *cmdy_shape_attributes(const CmdyZigCell *,uint8_t selected,uint8_t failed,const CmdyShapeStyle *);
const void *cmdy_shape_map_color(uint32_t,uint8_t foreground,uint8_t bold,const CmdyShapeStyle *);
uint8_t cmdy_shape_explicit_background(const CmdyZigCell *);
const void *cmdy_shape_font_variant(const void *font,uint8_t bold,uint8_t italic);
typedef struct CmdyShapeMetrics { double width,height,baseline; } CmdyShapeMetrics;
CmdyShapeMetrics cmdy_shape_metrics(const void *font,double multiplier,double scale);
#ifdef __cplusplus
}
#endif
#endif
