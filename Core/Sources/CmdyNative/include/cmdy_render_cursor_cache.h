#ifndef CMDY_RENDER_CURSOR_CACHE_H
#define CMDY_RENDER_CURSOR_CACHE_H
#include "cmdy_render_frame_input.h"
#ifdef __cplusplus
extern "C" {
#endif
typedef struct CmdyRenderCursorCache CmdyRenderCursorCache;
typedef struct CmdyRenderCursorFrames CmdyRenderCursorFrames;
typedef struct {
    CmdyRenderFrameIdentity identity;
    double x, y, scale, viewport_width, viewport_height, activity_time, active_until;
    size_t width, height, count, bytes_per_frame;
    const uint8_t *bytes; /* Immutable tightly packed BGRA8; count consecutive images. */
    size_t backing_width, backing_height, backing_byte_count;
    const uint8_t *backing_bytes; /* Optional opaque full viewport at phase zero. */
} CmdyRenderCursorFramesView;
enum { CMDY_CURSOR_CACHE_READY = 0, CMDY_CURSOR_CACHE_CANCELLED = 1, CMDY_CURSOR_CACHE_FAILED = 2 };
typedef void (*CmdyRenderCursorCacheCallback)(void *, uint32_t, CmdyRenderCursorFrames *);
/* Begin only on the frame's scoped GPU worker, for a stationary focused cursor.
 * Unsupported inputs (including effects, translucent backgrounds and images)
 * return NULL and leave callback context caller-owned. Successful admission
 * retains the immutable frame, returns one caller-owned handle, and guarantees
 * exactly one worker callback followed by dispose. The result is borrowed for
 * that callback; retain it to deliver off-worker. No host/UI call occurs here.
 * Work yields between GPU completions and uses a separate renderer/scheduler.
 * At most 60 phase images / 2 MiB of raw pixels are allocated. The caller must
 * additionally fence content revisions and visible-layer publication.
 * Cancellation never waits. Keep a live handle while cancelling; release it
 * once producers stop. Accepted work drains even after worker stop/invalidate.
 * Release alone does not cancel. No callback may join/destroy the worker. */
CmdyRenderCursorCache *cmdy_render_cursor_cache_begin(CmdyRenderWorker *, const void *device,
    CmdyRenderOwnedFrameInput *, uint32_t preset, double activity_time, double active_until,
    CmdyRenderCursorCacheCallback, void *context, CmdyRenderWorkerCallback dispose);
/* Same contract, plus one full-viewport phase-zero image, capped at 32 MiB.
 * This can back a coherent frozen terminal layer during the handoff to a newer
 * Metal frame. The sixty patch images retain their independent 2 MiB cap.
 * The backing's render/readback also yields through a worker completion. */
CmdyRenderCursorCache *cmdy_render_cursor_cache_begin_with_backing(CmdyRenderWorker *, const void *device,
    CmdyRenderOwnedFrameInput *, uint32_t preset, double activity_time, double active_until,
    CmdyRenderCursorCacheCallback, void *context, CmdyRenderWorkerCallback dispose);
void cmdy_render_cursor_cache_cancel(CmdyRenderCursorCache *);
void cmdy_render_cursor_cache_release(CmdyRenderCursorCache *);
CmdyRenderCursorFrames *cmdy_render_cursor_frames_retain(CmdyRenderCursorFrames *);
void cmdy_render_cursor_frames_release(CmdyRenderCursorFrames *);
/* Any thread with a live retained result. No mutation or lazy work. */
const CmdyRenderCursorFramesView *cmdy_render_cursor_frames_view(const CmdyRenderCursorFrames *);
#ifdef __cplusplus
}
#endif
#endif
