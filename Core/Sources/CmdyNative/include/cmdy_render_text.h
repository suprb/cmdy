#ifndef CMDY_RENDER_TEXT_H
#define CMDY_RENDER_TEXT_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
/* All opaque Apple objects are borrowed for the duration of a call unless
 * explicitly documented. Native result handles retain their own objects. */
typedef struct CmdyRenderRect { double x,y,width,height; } CmdyRenderRect;
typedef struct CmdyRenderColor { float r,g,b,a; } CmdyRenderColor;
typedef struct CmdyRenderSolid { CmdyRenderRect rect; CmdyRenderColor color; } CmdyRenderSolid;
typedef struct CmdyRenderTint { CmdyRenderRect rect,envelope; CmdyRenderColor color; uint8_t has_envelope,replaced_by_atlas; } CmdyRenderTint;
typedef struct CmdyRenderGlyphSeed { const void *font; CmdyRenderRect rect; CmdyRenderColor color; uint16_t glyph; } CmdyRenderGlyphSeed;
typedef struct CmdyRenderColorTile { CmdyRenderRect rect; intptr_t width,height; const uint8_t *bytes; size_t byte_count; } CmdyRenderColorTile;
typedef struct CmdyRenderTextSegment { const void *attributed_string; intptr_t column,column_width,character_count; const intptr_t *boundaries; size_t boundary_count; uint8_t has_boundaries,disable_sharing; } CmdyRenderTextSegment;
typedef struct CmdyRenderBlockRect { uint8_t x0,x1,y0,y1; double alpha; } CmdyRenderBlockRect;
typedef struct CmdyRenderBlock { intptr_t column,column_width; uint32_t code_point; const CmdyRenderBlockRect *rects; size_t rect_count; const void *foreground; } CmdyRenderBlock;
typedef struct CmdyRenderBox { intptr_t column,column_width; uint32_t code_point; const void *foreground; } CmdyRenderBox;
typedef struct CmdyRenderRowInput {
 const CmdyRenderTextSegment *segments; size_t segment_count;
 const CmdyRenderBlock *blocks; size_t block_count;
 const CmdyRenderBox *boxes; size_t box_count;
 intptr_t cols,width,height;
 double cell_width,cell_height,scale,underline_position,underline_thickness;
 const void *normal_font,*foreground;
 float coverage_exponent; uint8_t snaps_y,antialias_blocks,ascii_caching,font_caching;
} CmdyRenderRowInput;
typedef struct CmdyRenderRowRaster CmdyRenderRowRaster;
typedef struct CmdyRenderRowView {
 const uint8_t *coverage; size_t coverage_count;
 const CmdyRenderColorTile *color_tiles; size_t color_tile_count;
 const CmdyRenderSolid *backgrounds; size_t background_count;
 const CmdyRenderTint *tints; size_t tint_count;
 const CmdyRenderGlyphSeed *glyphs; size_t glyph_count;
 const CmdyRenderSolid *decorations; size_t decoration_count;
 intptr_t width,height;
} CmdyRenderRowView;
CmdyRenderRowRaster *cmdy_render_row_create(const CmdyRenderRowInput *);
void cmdy_render_row_free(CmdyRenderRowRaster *);
void cmdy_render_row_view(const CmdyRenderRowRaster *,CmdyRenderRowView *);
typedef struct CmdyRenderRowFonts CmdyRenderRowFonts;
/* Optional process-lifetime font registration hook. Install once before using
 * the renderer; returns zero for a null hook or a second installation. The hook
 * runs synchronously, at most one caller at a time, before shaping text whose
 * primary font lacks a glyph. It must not reenter the renderer. Return nonzero
 * when fallback fonts are ready; zero leaves registration retryable. Without a
 * hook the renderer uses the fonts already registered by the embedding app. */
typedef uint8_t (*CmdyRenderFontFallbackLoader)(void);
uint8_t cmdy_render_set_font_fallback_loader(CmdyRenderFontFallbackLoader);
CmdyRenderRowFonts *cmdy_render_fonts_create(double scale,const void *normal,uint8_t caching);
void cmdy_render_fonts_free(CmdyRenderRowFonts *);
/* These getters return +1 retained font objects. */
const void *cmdy_render_fonts_scaled(CmdyRenderRowFonts *,const void *source);
const void *cmdy_render_fonts_shaping(CmdyRenderRowFonts *,const void *source);
const void *cmdy_render_shaping_font(const void *source);
size_t cmdy_render_fonts_count(const CmdyRenderRowFonts *,uint8_t shaping);
uint8_t cmdy_render_fonts_additional_storage(const CmdyRenderRowFonts *,uint8_t shaping);
CmdyRenderColor cmdy_render_color(const void *color);
uint64_t cmdy_render_packed_color(const void *color);
double cmdy_render_centered_baseline(double row_height,double ascent,double descent,double leading,uint8_t snaps);
double cmdy_render_grid_baseline(double row_height,const void *font,double scale,uint8_t snaps);
double cmdy_render_cell_text_origin(double x,double cell_width,double line_width);
CmdyRenderRect cmdy_render_strikethrough(CmdyRenderRect,double y,double thickness);
size_t cmdy_render_underlines(uint8_t style,CmdyRenderRect,double y,double thickness,CmdyRenderRect *out,size_t capacity);
float cmdy_render_block_coverage(double alpha,float exponent);
intptr_t cmdy_render_box_thickness(double thickness,double scale);
/* Exact Unicode 16 extended grapheme boundaries, including the leading zero. */
size_t cmdy_render_text_boundaries(const uint16_t *,size_t,intptr_t *out,size_t capacity);
CmdyRenderBlockRect cmdy_render_block_rect(uint8_t x0,uint8_t x1,uint8_t y0,uint8_t y1,double alpha);
CmdyRenderRect cmdy_render_block_geometry(CmdyRenderBlockRect,double x,double y,double x_eighth,double y_eighth,double height);
typedef struct CmdyRenderPoint { double x,y; } CmdyRenderPoint;
CmdyRenderPoint cmdy_render_canvas_point(double x,double y,intptr_t width,intptr_t height,double unit_x,double unit_y);
uint8_t cmdy_render_solid_merge(CmdyRenderSolid *,const CmdyRenderSolid *);
size_t cmdy_render_block_rects(uint32_t,CmdyRenderBlockRect *out,size_t capacity);
void cmdy_render_box_draw(uint32_t,void *context,double x,double y,double width,double height,double scale,const void *color,intptr_t thickness);
intptr_t cmdy_render_diagonal_thickness(intptr_t);
double cmdy_render_arc_axis(intptr_t length,intptr_t thickness);
typedef struct CmdyRenderSpan { intptr_t lower,upper; } CmdyRenderSpan;
size_t cmdy_render_dash_spans(intptr_t length,intptr_t count,uint8_t horizontal,uint8_t heavy,intptr_t thickness,CmdyRenderSpan *out,size_t capacity);
void cmdy_render_canvas_line(void *context,double x,double y,intptr_t width,intptr_t height,intptr_t minimum,double x0,double y0,double x1,double y1,intptr_t thickness);
void cmdy_render_canvas_box(void *context,double x,double y,intptr_t width,intptr_t height,intptr_t bx,intptr_t by,intptr_t bw,intptr_t bh);
CmdyRenderSpan cmdy_render_centered_band(intptr_t length,intptr_t thickness,uint8_t upper_bias);
typedef struct CmdyRenderGlyphBitmap CmdyRenderGlyphBitmap;
typedef struct CmdyRenderGlyphBitmapView { intptr_t width,height; double bearing_x,bearing_y; const uint8_t *bytes; size_t byte_count; uint8_t is_color; } CmdyRenderGlyphBitmapView;
uint8_t cmdy_render_glyph_has_bounds(const void *,uint16_t glyph);
CmdyRenderGlyphBitmap *cmdy_render_glyph_rasterize(const void *,uint16_t glyph);
void cmdy_render_glyph_bitmap_view(const CmdyRenderGlyphBitmap *,CmdyRenderGlyphBitmapView *);
void cmdy_render_glyph_bitmap_free(CmdyRenderGlyphBitmap *);
/* Shared-key decoding accepts only these exact modeled AppKit attributes. */
typedef struct CmdyRenderAttributeKey {
 const void *objects[8]; int64_t integers[4]; uint64_t kern_bits; uint32_t present;
} CmdyRenderAttributeKey;
uint8_t cmdy_render_attribute_key(const void *dictionary,CmdyRenderAttributeKey *);
typedef struct CmdyRenderTextKey CmdyRenderTextKey;
CmdyRenderTextKey *cmdy_render_text_key_create(const CmdyRenderRowInput *);
uint8_t cmdy_render_text_key_equal(const CmdyRenderTextKey *,const CmdyRenderTextKey *);
void cmdy_render_text_key_free(CmdyRenderTextKey *);
CmdyRenderTextKey *cmdy_render_text_key_retain(CmdyRenderTextKey *);
uint64_t cmdy_render_text_key_hash(const CmdyRenderTextKey *);
typedef struct CmdyRenderAtlas CmdyRenderAtlas;
typedef struct CmdyRenderAtlasRegion { intptr_t page,x,y,width,height; uint64_t generation; } CmdyRenderAtlasRegion;
CmdyRenderAtlas *cmdy_render_atlas_create(const void *device,intptr_t size,intptr_t pages,uint8_t bgra,uint8_t frozen);
void cmdy_render_atlas_free(CmdyRenderAtlas *);
const void *cmdy_render_atlas_texture(const CmdyRenderAtlas *);
intptr_t cmdy_render_atlas_size(const CmdyRenderAtlas *);
intptr_t cmdy_render_atlas_evicted_page(const CmdyRenderAtlas *);
uint64_t cmdy_render_atlas_generation(const CmdyRenderAtlas *,intptr_t page);
void cmdy_render_atlas_touch(CmdyRenderAtlas *,intptr_t page);
uint8_t cmdy_render_atlas_region(CmdyRenderAtlas *,intptr_t width,intptr_t height,CmdyRenderAtlasRegion *);
void cmdy_render_atlas_write(CmdyRenderAtlas *,const CmdyRenderAtlasRegion *,const uint8_t *bytes,size_t byte_count,intptr_t width,intptr_t height,intptr_t padding);
uint8_t cmdy_render_atlas_insert_glyph(CmdyRenderAtlas *,const CmdyRenderGlyphBitmapView *,intptr_t padding,CmdyRenderAtlasRegion *);
typedef struct CmdyRenderBufferRing CmdyRenderBufferRing;
CmdyRenderBufferRing *cmdy_render_buffer_ring_create(const void *device,size_t frames,size_t minimum,size_t alignment);
void cmdy_render_buffer_ring_free(CmdyRenderBufferRing *);
void cmdy_render_buffer_ring_begin(CmdyRenderBufferRing *);
const void *cmdy_render_buffer_ring_write(CmdyRenderBufferRing *,const void *,size_t bytes,size_t *offset);
size_t cmdy_render_buffer_ring_allocations(const CmdyRenderBufferRing *);
#ifdef __cplusplus
}
#endif
#endif
