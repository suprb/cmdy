#ifndef CMDY_RENDER_INPUT_H
#define CMDY_RENDER_INPUT_H
#include "cmdy_render_text.h"
#include "cmdy_render_shape.h"
#ifdef __cplusplus
extern "C" {
#endif
typedef struct CmdyRenderOwnedRowInput CmdyRenderOwnedRowInput;
enum {
    CMDY_RENDER_INPUT_OK = 0,
    CMDY_RENDER_INPUT_INVALID = 1,
    CMDY_RENDER_INPUT_UNSUPPORTED_ATTRIBUTES = 2,
    CMDY_RENDER_INPUT_OUT_OF_MEMORY = 3
};
/* Capture on the host's source owner, with its current appearance. Copies every
 * declared nested array and attributed string. Fonts/numbers are immutable;
 * colors are resolved into owned device-RGB values. Supports the renderer's
 * modeled font/color/number attributes. Unknown attributes return UNSUPPORTED
 * instead of being dropped or shared with a background worker.
 * Borrowed pointer/count pairs must describe valid readable memory for this
 * call. No producer mutation is allowed during capture. */
CmdyRenderOwnedRowInput *cmdy_render_input_capture(const CmdyRenderRowInput *, uint32_t *status);
typedef struct CmdyRenderRowStyle CmdyRenderRowStyle;
/* Capture on the style owner under its effective appearance. Resolves and owns
 * a private immutable style; never shares the UI style's non-atomic references.
 * Retain/release are atomic. A live reference is required before retaining. */
CmdyRenderRowStyle *cmdy_render_row_style_capture(const CmdyShapeStyle *,uint32_t *status);
CmdyRenderRowStyle *cmdy_render_row_style_retain(CmdyRenderRowStyle *);
void cmdy_render_row_style_release(CmdyRenderRowStyle *);
typedef struct CmdyRenderRowParameters CmdyRenderRowParameters;
/* Freeze frame-wide scalar raster parameters, font and resolved foreground
 * once on the producer under its appearance. Segment/block/box pointers and
 * counts must all be zero. The packet is immutable with atomic references.
 * It contains no dynamic color, UI source object or callback. Capture failure
 * leaves caller ownership unchanged; status uses CMDY_RENDER_INPUT_* values. */
CmdyRenderRowParameters *cmdy_render_row_parameters_capture(const CmdyRenderRowInput *,uint32_t *status);
CmdyRenderRowParameters *cmdy_render_row_parameters_retain(CmdyRenderRowParameters *);
void cmdy_render_row_parameters_release(CmdyRenderRowParameters *);
/* Capture on any owner while the source line is stable. Freezes the COW line
 * and retains the immutable style/parameter packets. No font/color resolution,
 * cell traversal, shaping or UI access occurs here. Caller references may be
 * released after return. Retain/release require an existing live reference.
 * Mutable source lines must not be changed concurrently with this call. */
CmdyRenderOwnedRowInput *cmdy_render_input_capture_frozen(const CmdyZigLine *,intptr_t source_row,
    CmdyRenderRowStyle *,CmdyRenderRowParameters *,uint32_t *status);
/* Captures a frozen native line and scalar raster parameters on the producer.
 * Parameters must have no segment/block/box arrays. Fonts and the foreground
 * are captured under the producer appearance; no cell classification or text
 * shaping/copying occurs.
 * The source line/style can be mutated or destroyed after this returns.
 * Images remain separate frame-row inputs. Selection remains frame geometry. */
CmdyRenderOwnedRowInput *cmdy_render_input_capture_deferred(const CmdyZigLine *,intptr_t source_row,
    CmdyRenderRowStyle *,const CmdyRenderRowInput *parameters,uint32_t *status);
/* Call on the render worker. Prepares a deferred row at most once, publishing
 * immutable text, placeholders and revision eligibility together. Concurrent callers serialize the
 * first preparation; a failed preparation remains retryable. Eager inputs are
 * returned directly. The caller must hold the input alive throughout use. */
const CmdyRenderRowInput *cmdy_render_input_prepare(CmdyRenderOwnedRowInput *,uint32_t *status);
/* Deferred view is NULL until prepare succeeds; this getter never prepares. */
/* Immutable view, valid while a reference is held. Retain/release are atomic;
 * a caller must already own a live reference before retaining another one. */
const CmdyRenderRowInput *cmdy_render_input_view(const CmdyRenderOwnedRowInput *);
/* Additional decoded placeholders from deferred input. Borrowed after a
 * successful prepare; eager input returns no additional placeholders. */
const CmdyShapePlaceholder *cmdy_render_input_placeholders(const CmdyRenderOwnedRowInput *,size_t *count);
/* Nonblocking eligibility query; never scans cells or prepares text. Returns
 * zero until deferred preparation succeeds, then its immutable classification.
 * Zero also covers eager input and rows with procedural glyphs/placeholders.
 * The caller must retain the input while querying from any thread. */
uint8_t cmdy_render_input_revision_reusable(const CmdyRenderOwnedRowInput *);
CmdyRenderOwnedRowInput *cmdy_render_input_retain(CmdyRenderOwnedRowInput *);
void cmdy_render_input_release(CmdyRenderOwnedRowInput *);
#ifdef __cplusplus
}
#endif
#endif
