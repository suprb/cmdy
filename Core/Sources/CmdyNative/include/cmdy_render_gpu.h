#ifndef CMDY_RENDER_GPU_H
#define CMDY_RENDER_GPU_H
#include "cmdy_render_text.h"
#include "cmdy_render_worker.h"
#ifdef __cplusplus
extern "C" {
#endif
typedef struct CmdyRenderGPU CmdyRenderGPU;
typedef struct CmdyRenderGPURow CmdyRenderGPURow;
typedef struct CmdyRenderOwnedImageInput CmdyRenderOwnedImageInput;
typedef void (*CmdyRenderGPUEvent)(void *context,uint32_t event);
CmdyRenderGPU *cmdy_gpu_create(const void *device,uint64_t format,size_t samples,double now,char *error,size_t capacity);
/* Call on the specified worker, created with a synchronous autorelease-pool
 * scope. All GPU/row/cache/schedule operations and borrowed handles belong to
 * that worker. Off-owner GPU calls fail/no-op. Events run on the worker.
 * Destroy is the exception: stop handle producers, then call destroy exactly
 * once from any thread before joining the worker. It queues teardown even after
 * stop. Keep event context alive until worker join. Reserved GPU/image jobs are
 * drained on that owner; destroy does not synchronously release the handle. */
CmdyRenderGPU *cmdy_gpu_create_on_worker(CmdyRenderWorker *,const void *device,uint64_t format,size_t samples,double now,char *error,size_t capacity);
void cmdy_gpu_destroy(CmdyRenderGPU *);
void cmdy_gpu_set_event(CmdyRenderGPU *,CmdyRenderGPUEvent,void *);
void *cmdy_zig_gpu_schedule(CmdyRenderGPU *);
const char *cmdy_gpu_shader_source(uint32_t kind);
const void *cmdy_gpu_shader_library(const void *device,uint32_t kind,char *,size_t); /* +1 */
const void *cmdy_gpu_effect_pipeline(const void *device,uint64_t format,size_t samples,uint8_t glyph,char *,size_t); /* +1 */
const void *cmdy_gpu_shared_identity(const void *device,uint64_t format,size_t samples,char *,size_t); /* +1 */
const void *cmdy_gpu_shared_queue(const void *device,uint64_t format,size_t samples,char *,size_t); /* +1 */
void cmdy_gpu_shared_reset(void);
size_t cmdy_gpu_shared_constructions(void);
uint8_t cmdy_gpu_load_shader(CmdyRenderGPU *,const char *source,char *,size_t);
uint8_t cmdy_gpu_has_user_shader(const CmdyRenderGPU *);
uint8_t cmdy_gpu_user_shader_uses_time(const CmdyRenderGPU *);
void cmdy_gpu_set_preset(CmdyRenderGPU *,uint32_t preset);
void cmdy_gpu_resize(CmdyRenderGPU *);
void cmdy_gpu_cursor_blink(CmdyRenderGPU *,uint8_t eligible);
CmdyRenderRect cmdy_gpu_kitty_fit(double width,double height,CmdyRenderRect container);
const void *cmdy_gpu_scaled_font(const void *font,double scale); /* +1 */
typedef struct CmdyGpuFrameMetrics { double cell_width,cell_height,cursor_cell_height; intptr_t row_width,row_height; uint8_t valid; } CmdyGpuFrameMetrics;
CmdyGpuFrameMetrics cmdy_gpu_frame_metrics(intptr_t rows,intptr_t cols,double cell_width,double cell_height,double scale,double bounds_width,double bounds_height,double drawable_width,double drawable_height);
typedef struct CmdyGpuRowKey {
 intptr_t absolute_row; uint64_t version; uint32_t line_mode;
 intptr_t cols,width,height; uint64_t scale_bits;
 const char *font_name; uint64_t font_size_bits;
 uint8_t alternate_buffer;
 intptr_t kitty_images,kitty_placements;
 uint32_t kitty_next_image,kitty_next_placement;
 uint64_t foreground,background;
 uint32_t preset; uint8_t antialias_blocks,buffering_mode;
} CmdyGpuRowKey;
typedef struct CmdyGpuRowRevision { uint64_t content,context; } CmdyGpuRowRevision;
typedef struct CmdyGpuImagePlacement {
 const void *owner; const void *image;
 intptr_t col,z_index,width,height,offset_x,offset_y;
 uint32_t kitty_image_id; uint8_t has_kitty_id,is_kitty;
 /* Native encoded input replaces owner/image in captured-frame rendering. */
 CmdyRenderOwnedImageInput *owned_image;
} CmdyGpuImagePlacement;
typedef struct CmdyGpuPlaceholder {
 uint32_t image_id,placement_id; intptr_t row,col,placeholder_row,placeholder_col,msb;
} CmdyGpuPlaceholder;
typedef struct CmdyGpuAtlasGlyph { CmdyRenderRect rect,atlas_rect; CmdyRenderColor color; } CmdyGpuAtlasGlyph;
typedef struct CmdyGpuColorLayer { const void *texture; CmdyRenderRect rect; } CmdyGpuColorLayer;
typedef struct CmdyGpuRowView {
 const void *coverage_texture;
 const CmdyGpuColorLayer *color_layers; size_t color_layer_count;
 const CmdyRenderSolid *backgrounds; size_t background_count;
 const CmdyRenderTint *tints; size_t tint_count;
 const CmdyGpuAtlasGlyph *atlas_glyphs; size_t atlas_glyph_count;
 const CmdyRenderSolid *decorations; size_t decoration_count;
 const CmdyGpuImagePlacement *images; size_t image_count;
 const CmdyGpuPlaceholder *placeholders; size_t placeholder_count;
 /* Coverage texture dimensions. Row/tint geometry retains full row coordinates;
  * transparent trailing columns may be omitted with a zero clamp border. */
 intptr_t width,height; uint64_t last_use;
} CmdyGpuRowView;
/* Lookup never evaluates line content. This preserves the snapshot-first and
 * immutable revision shortcuts without calling back through the host. */
const CmdyRenderGPURow *cmdy_gpu_row_lookup(CmdyRenderGPU *,const CmdyGpuRowKey *,uint8_t dirty,CmdyGpuRowRevision,const CmdyRenderRowInput *raster_inputs);
const CmdyRenderGPURow *cmdy_gpu_row_resolve(CmdyRenderGPU *,const CmdyGpuRowKey *,CmdyGpuRowRevision,const CmdyRenderRowInput *,const CmdyGpuImagePlacement *,size_t,const CmdyGpuPlaceholder *,size_t);
void cmdy_gpu_row_view(const CmdyRenderGPURow *,CmdyGpuRowView *);
/* Frame references are separate from row-cache residency. Retain before any
 * host callback can invalidate/reconfigure the cache; release after encoding. */
const CmdyRenderGPURow *cmdy_gpu_row_retain(const CmdyRenderGPURow *);
void cmdy_gpu_row_release(const CmdyRenderGPURow *);
const CmdyRenderTextKey *cmdy_gpu_row_text_key(const CmdyRenderGPURow *); /* borrowed */
CmdyGpuRowRevision cmdy_gpu_row_revision(const CmdyRenderGPURow *);
void cmdy_gpu_row_raster_inputs(const CmdyRenderGPURow *,CmdyRenderRowInput *);
const void *cmdy_gpu_weak_owner(const void *weak_box); /* +1 or NULL */
void cmdy_gpu_rows_clear(CmdyRenderGPU *);
void cmdy_gpu_rows_trim(CmdyRenderGPU *,const intptr_t *visible,size_t count,size_t visible_count);
void cmdy_gpu_rows_trim_visible(CmdyRenderGPU *,const intptr_t *visible,size_t count,size_t grid_rows);
size_t cmdy_gpu_rows_count(const CmdyRenderGPU *);
size_t cmdy_gpu_rows_bytes(const CmdyRenderGPU *);
size_t cmdy_gpu_rows_keys(const CmdyRenderGPU *,intptr_t *out,size_t capacity);
const CmdyRenderGPURow *cmdy_gpu_row_import(CmdyRenderGPU *,const CmdyGpuRowKey *,const CmdyGpuRowView *);
uint64_t cmdy_gpu_counter(uint32_t kind);
void cmdy_gpu_counter_set(uint32_t kind,uint64_t value);
const void *cmdy_gpu_image_texture(CmdyRenderGPU *,const void *owner,const void *image);
size_t cmdy_gpu_image_attempts(const CmdyRenderGPU *);
size_t cmdy_gpu_image_pending(const CmdyRenderGPU *);
typedef struct CmdyGpuFrameRow {
 const CmdyRenderGPURow *entry; intptr_t display_index,source_row;
 uint32_t line_mode; intptr_t selection_lower,selection_upper; uint8_t has_selection;
} CmdyGpuFrameRow;
typedef struct CmdyGpuKittyImage {
 uint32_t image_id; uint8_t kind; const uint8_t *bytes; size_t byte_count; intptr_t width,height;
} CmdyGpuKittyImage;
typedef struct CmdyGpuKittyPlacement {
 uint32_t image_id,placement_id; intptr_t cols,rows,offset_x,offset_y;
} CmdyGpuKittyPlacement;
typedef struct CmdyGpuFrame {
 const void *drawable,*pass;
 const CmdyGpuFrameRow *rows; size_t row_count;
 const CmdyGpuKittyImage *kitty_images; size_t kitty_image_count;
 const CmdyGpuKittyPlacement *kitty_placements; size_t kitty_placement_count;
 const uint32_t *live_kitty_ids; size_t live_kitty_count;
 double width,height,scale,cell_width,cell_height,top_inset,bottom_inset,left_inset,content_x,scroll_pixels,image_scale;
 intptr_t grid_rows,grid_cols,display_top_row,cursor_source_row,cursor_display_row,cursor_col;
 uint32_t cursor_style; uint8_t cursor_valid,cursor_hidden,host_cursor_hidden,caret_focused,smooth_cursor,live_resize;
 float cursor_speed,cursor_max_distance;
 double cursor_natural_height,underline_thickness;
 CmdyRenderColor background,selection,caret,caret_text;
 double now,activity_keypress_time; float typing_rate;
 int32_t shader_mode; float shader_energy,shader_velocity;
 uint64_t trace_started; intptr_t trace_source;
} CmdyGpuFrame;
/* A non-null pass is required. Null drawable encodes offscreen without present.
 * Worker mode clears its in-flight state before delivering completion event 1.
 * Target/surface invalidation must be ordered by the caller before commit. */
uint8_t cmdy_gpu_draw(CmdyRenderGPU *,const CmdyGpuFrame *);
typedef struct CmdyGpuGlyphEntry {
 intptr_t page,x,y,width,height,bitmap_width,bitmap_height;
 uint64_t generation; double bearing_x,bearing_y; uint8_t is_color;
} CmdyGpuGlyphEntry;
uint8_t cmdy_gpu_cache_glyph(CmdyRenderGPU *,const void *font,uint16_t glyph,CmdyGpuGlyphEntry *);
size_t cmdy_gpu_color_atlas_allocations(const CmdyRenderGPU *);
size_t cmdy_gpu_color_atlas_capacity(const CmdyRenderGPU *);
#ifdef __cplusplus
}
#endif
#endif
