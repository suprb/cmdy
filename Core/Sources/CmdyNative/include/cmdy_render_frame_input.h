#ifndef CMDY_RENDER_FRAME_INPUT_H
#define CMDY_RENDER_FRAME_INPUT_H
#include "cmdy_render_input.h"
#include "cmdy_render_gpu.h"
#include "cmdy_images.h"
#include "cmdy_buffer.h"
#ifdef __cplusplus
extern "C" {
#endif
typedef struct CmdyRenderOwnedFrameInput CmdyRenderOwnedFrameInput;
typedef struct CmdyRenderOwnedFrameRowInput CmdyRenderOwnedFrameRowInput;
typedef struct CmdyRenderOwnedTarget CmdyRenderOwnedTarget;
typedef struct CmdyRenderOwnedGraphicsInput CmdyRenderOwnedGraphicsInput;
typedef struct CmdyRenderGraphicsView {
    const CmdyGpuKittyImage *images;
    size_t image_count;
    const CmdyGpuKittyPlacement *placements;
    size_t placement_count;
    const uint32_t *live_ids;
    size_t live_count;
} CmdyRenderGraphicsView;
/* Capture on the terminal owner while the store is stable. Copies small image
 * and placement metadata and retains immutable payloads without copying bytes
 * or retaining the mutable store/images and their identity observers. Both
 * buffer placement sets are frozen. Atomic ownership permits worker reads and
 * release; a payload's final release can run its original owner deallocator. */
CmdyRenderOwnedGraphicsInput *cmdy_render_graphics_input_capture(const CmdyZigGraphics *, uint32_t *status);
CmdyRenderOwnedGraphicsInput *cmdy_render_graphics_input_retain(CmdyRenderOwnedGraphicsInput *);
void cmdy_render_graphics_input_release(CmdyRenderOwnedGraphicsInput *);
const CmdyRenderGraphicsView *cmdy_render_graphics_input_view(const CmdyRenderOwnedGraphicsInput *, uint8_t alternate_buffer);
typedef struct CmdyRenderImageInput {
    uint8_t identity[16];
    uint8_t kind; /* 0 PNG, 1 RGBA; same payload convention as the source API. */
    const uint8_t *bytes;
    size_t byte_count;
    intptr_t width, height;
} CmdyRenderImageInput;
/* Identity must change when pixels change. Capture copies bytes, without image
 * decoding or host objects. Empty/invalid encoded data is preserved for the
 * decoder's existing failure behavior. A producer may cache the owned handle
 * by stable image identity, avoiding pixel copies on subsequent frames. */
CmdyRenderOwnedImageInput *cmdy_render_image_input_capture(const CmdyRenderImageInput *, uint32_t *status);
const CmdyRenderImageInput *cmdy_render_image_input_view(const CmdyRenderOwnedImageInput *);
CmdyRenderOwnedImageInput *cmdy_render_image_input_retain(CmdyRenderOwnedImageInput *);
void cmdy_render_image_input_release(CmdyRenderOwnedImageInput *);

typedef struct CmdyRenderFrameIdentity {
    uint64_t surface, epoch, sequence; /* Nonzero; the owner controls ordering. */
} CmdyRenderFrameIdentity;
typedef struct CmdyRenderFrameImageInput {
    CmdyRenderOwnedImageInput *payload;
    CmdyGpuImagePlacement placement; /* owner/image/owned_image must be NULL. */
} CmdyRenderFrameImageInput;
typedef struct CmdyRenderFrameRowInput {
    CmdyGpuRowKey key;
    size_t font_name_bytes; /* Excludes terminator; capture adds its own NUL. */
    CmdyGpuRowRevision revision;
    CmdyRenderOwnedRowInput *text;
    const CmdyRenderFrameImageInput *images;
    size_t image_count;
    const CmdyGpuPlaceholder *placeholders;
    size_t placeholder_count;
    CmdyGpuFrameRow placement; /* entry must be NULL: resolve on the worker. */
} CmdyRenderFrameRowInput;
/* Freeze a row once while its borrowed values are stable. Owns the key's font
 * name, image placements and placeholders; retains immutable text/image handles.
 * The same validation as frame capture applies. No GPU or host objects survive
 * capture. Per-frame placement comes from CmdyRenderFrameRowReference below. */
CmdyRenderOwnedFrameRowInput *cmdy_render_frame_row_capture(const CmdyRenderFrameRowInput *, uint32_t *status);
CmdyRenderOwnedFrameRowInput *cmdy_render_frame_row_retain(CmdyRenderOwnedFrameRowInput *);
void cmdy_render_frame_row_release(CmdyRenderOwnedFrameRowInput *);
typedef struct CmdyRenderFrameRowReference {
    CmdyRenderOwnedFrameRowInput *row;
    CmdyGpuFrameRow placement; /* entry must be NULL. */
} CmdyRenderFrameRowReference;
typedef struct CmdyRenderFrameInput {
    CmdyRenderFrameIdentity identity;
    /* Includes cursor/selection/colors/geometry/motion/activity/shader values
     * and Kitty payloads. drawable/pass/rows must be NULL, row_count zero.
     * GPU targets are supplied separately under the surface owner's ordering. */
    CmdyGpuFrame parameters;
    intptr_t buffer_line_count, retained_row_origin, live_top_row;
    uint8_t alternate_buffer;
    const CmdyRenderFrameRowInput *rows;
    size_t row_count;
} CmdyRenderFrameInput;
/* A frozen terminal viewport and UI-only settings. Capture retains the three
 * immutable native owners and copies the key's font name. It never traverses
 * rows. Selection endpoints are normalized; columns are clamped on the worker.
 * The row key supplies common raster values; row identity/mode come from the
 * snapshot. The snapshot must cover every requested visible/fringe row. */
typedef struct CmdyRenderViewportInput {
    CmdyZigBufferSnapshot *snapshot;
    CmdyRenderRowStyle *style;
    CmdyRenderRowParameters *raster;
    CmdyGpuRowKey key;
    size_t font_name_bytes;
    intptr_t fringe_rows;
    uint8_t has_selection;
    intptr_t selection_start_row, selection_start_col;
    intptr_t selection_end_row, selection_end_col;
    /* Coordinate offset for UI failed-row decorations after history trimming. */
    intptr_t style_row_offset;
    uint64_t model_generation;
} CmdyRenderViewportInput;
/* input contains scalar metadata only. Optional graphics are shared. The full
 * frame view contains scalar/graphics values with an empty row array; the GPU
 * draw worker traverses the viewport directly and uses its own row cache.
 * The general eager/referenced frame contracts remain unchanged. */
CmdyRenderOwnedFrameInput *cmdy_render_frame_input_capture_viewport(const CmdyRenderFrameInput *,
    const CmdyRenderViewportInput *, CmdyRenderOwnedGraphicsInput *, uint32_t *status);
/* Call on the producer while borrowed memory is stable. Retains text and image
 * handles, copies every other nested array/string/payload and all scalar values.
 * No host, cache, source callback or GPU resource is retained. Rejection leaves
 * ownership with the caller; status uses CMDY_RENDER_INPUT_* constants.
 * Identity is captured evidence, not a stale-presentation fence. */
CmdyRenderOwnedFrameInput *cmdy_render_frame_input_capture(const CmdyRenderFrameInput *, uint32_t *status);
/* Capture shared immutable row descriptions plus a copied placement/reference
 * array. input.rows must be NULL and row_count zero; Kitty values are copied as
 * for eager capture. Reserves output storage now, but the first full view call
 * assembles its rows on the calling worker. Unchanged row strings, image arrays
 * and placeholders are never recopied. Failure releases all acquired references.
 * No callbacks run at capture, assembly or release. */
CmdyRenderOwnedFrameInput *cmdy_render_frame_input_capture_referenced(const CmdyRenderFrameInput *,
    const CmdyRenderFrameRowReference *, size_t row_count, uint32_t *status);
/* As referenced capture, but retains one frozen graphics owner. All input
 * parameters Kitty pointers/counts must be NULL/zero. The frame selects the
 * primary/alternate placement set from alternate_buffer (which must be 0/1).
 * No image bytes or graphics metadata arrays are copied per frame. */
CmdyRenderOwnedFrameInput *cmdy_render_frame_input_capture_referenced_graphics(const CmdyRenderFrameInput *,
    const CmdyRenderFrameRowReference *, size_t row_count, CmdyRenderOwnedGraphicsInput *, uint32_t *status);
/* Reuse every immutable nested row/string/image/Kitty value from previous and
 * replace all scalar metadata from update. The caller must establish that row
 * contents, row placements and selection ranges, and Kitty resources are
 * unchanged. update's rows and every parameters array/target pointer must be
 * NULL with zero counts. Surface and epoch must match previous; sequence must
 * be nonzero. No source callbacks, resource copies or per-row retain operations
 * occur. The new frame owns one reference to the original content owner; reuse
 * chains do not retain intermediate frames. Failure leaves previous unchanged.
 * This does not relax the worker's identity or presentation fences. */
CmdyRenderOwnedFrameInput *cmdy_render_frame_input_reuse(CmdyRenderOwnedFrameInput *previous,
    const CmdyRenderFrameInput *update, uint32_t *status);
/* Scalar metadata is always available without assembly, allocation or locking.
 * Every array/target pointer is NULL with zero counts. Use for producer/session
 * admission and identity checks, keeping full row assembly on the render worker. */
const CmdyRenderFrameInput *cmdy_render_frame_input_metadata(const CmdyRenderOwnedFrameInput *);
/* Full views/nested pointers are immutable and valid while a reference is held.
 * Concurrent first views assemble once; this operation cannot allocate or fail
 * for a valid frame. Prefer metadata above when rows are unnecessary.
 * Retain/release are atomic; retaining requires an existing live reference. */
const CmdyRenderFrameInput *cmdy_render_frame_input_view(const CmdyRenderOwnedFrameInput *);
CmdyRenderOwnedFrameInput *cmdy_render_frame_input_retain(CmdyRenderOwnedFrameInput *);
void cmdy_render_frame_input_release(CmdyRenderOwnedFrameInput *);
/* Call on the GPU's worker. Resolves retained immutable text/image handles into
 * native rows, then encodes to the separately supplied target. No host/source
 * callbacks occur. The frame may be released after this call; cache and decode
 * references own any input still needed. A failed row fails the whole draw.
 * Epoch is checked at entry and again at final commit, serialized against worker
 * invalidation/stop and renderer close. Already-submitted GPU work is not revoked.
 * Raw targets remain caller-owned and caller-matched; prefer draw_target below. */
uint8_t cmdy_gpu_draw_captured(CmdyRenderGPU *,const CmdyRenderOwnedFrameInput *,
    const void *drawable,const void *pass);
/* Capture on the producer while the descriptor is stable. Copies the descriptor
 * and retains its resources and optional CAMetalDrawable. The three identity
 * values must be nonzero. If drawable is present its texture must be the pass's
 * color output. No host/source callbacks are retained. Atomic reference counts;
 * retaining requires an existing live reference. */
CmdyRenderOwnedTarget *cmdy_render_target_capture(CmdyRenderFrameIdentity,
    const void *drawable,const void *pass,uint32_t *status);
CmdyRenderOwnedTarget *cmdy_render_target_retain(CmdyRenderOwnedTarget *);
void cmdy_render_target_release(CmdyRenderOwnedTarget *);
/* Rejects identity/device/format/dimension mismatches before cache mutation.
 * A target is single-use once encoding is attempted, including an aborted
 * attempt. Capture a new target for retry/redraw. The frame may be reused.
 * Invalidation and stop prevent a not-yet-committed old frame from submission;
 * they do not wait for GPU execution/presentation of earlier submissions. */
uint8_t cmdy_gpu_draw_target(CmdyRenderGPU *,const CmdyRenderOwnedFrameInput *,CmdyRenderOwnedTarget *);
#ifdef __cplusplus
}
#endif
#endif
