#ifndef CMDY_RENDER_SESSION_H
#define CMDY_RENDER_SESSION_H
#include "cmdy_render_frame_input.h"
#include "cmdy_render_schedule.h"
#include "cmdy_render_cursor_cache.h"
#ifdef __cplusplus
extern "C" {
#endif
typedef struct CmdyRenderSession CmdyRenderSession;
enum {
    CMDY_SESSION_READY = 0, CMDY_SESSION_ACTIONS = 1,
    CMDY_SESSION_CAPTURE = 2, CMDY_SESSION_FRAME = 3, CMDY_SESSION_ERROR = 4,
    CMDY_SESSION_INSPECTION = 5, CMDY_SESSION_CAPACITY_AVAILABLE = 6,
    CMDY_SESSION_CURSOR_CACHE = 7, CMDY_SESSION_CURSOR_RETIRED = 8
};
enum {
    CMDY_SESSION_EVENT = 0, CMDY_SESSION_BEGIN_DRAW = 1,
    CMDY_SESSION_CAPTURE_FAILED = 2, CMDY_SESSION_CONFIG = 3,
    CMDY_SESSION_PRESET = 4, CMDY_SESSION_CANCEL_SCROLL = 5,
    CMDY_SESSION_CLEAR_ROWS = 6, CMDY_SESSION_INSPECT = 7,
    CMDY_SESSION_INPUT_ACTIVITY = 8, CMDY_SESSION_OBSERVE_FRAMES = 9
};
/* BEGIN_DRAW event: one viewport admission may consume one callback for the
 * exact same frame while it is still pending/in flight. All other draws remain ordinary. */
enum { CMDY_BEGIN_DRAW_ORDINARY = 0, CMDY_BEGIN_DRAW_VIEWPORT = 1 };
typedef struct {
    uint32_t kind, event;
    uint64_t request_id;
    CmdyRenderFrameIdentity identity;
    CmdyRenderScheduleEnvironment environment;
    CmdyRenderScheduleConfig config;
    double value, value2;
} CmdyRenderSessionCommand;
typedef struct {
    uint32_t kind, success, preset;
    uint64_t request_id;
    uint64_t source_revision;
    CmdyRenderFrameIdentity identity;
    CmdyRenderScheduleEnvironment environment;
    CmdyRenderScheduleConfig config;
    CmdyRenderScheduleInspection inspection;
    CmdyRenderScheduleActions actions;
    CmdyRenderDrawStart draw;
    size_t row_count, row_bytes; /* Only populated for INSPECTION. */
    uint64_t cursor_token, cursor_generation;
    CmdyRenderCursorFrames *cursor_frames; /* Borrowed only for CURSOR_CACHE. */
    char message[512];
} CmdyRenderSessionUpdate;
/* Called on the scoped worker without internal locks. Copy the borrowed update
 * before returning, then dispatch UI work to its owner. A delivery already in
 * progress may finish after close; hosts must discard queued updates after close, and obsolete epoch-scoped
 * CAPTURE/FRAME/errors. Ordered ACTIONS, READY and control replies must survive
 * epoch changes. No callback may join/destroy its session. */
typedef void (*CmdyRenderSessionCallback)(void *, const CmdyRenderSessionUpdate *);
/* GPU initialization is asynchronous: READY or ERROR reports the outcome.
 * A successful factory owns context until dispose runs after destroy's join.
 * A failed factory leaves context caller-owned. The device is retained. */
CmdyRenderSession *cmdy_render_session_create(const void *device, uint64_t format,
    size_t samples, uint64_t surface, double now, CmdyRenderSessionCallback,
    void *context, CmdyRenderWorkerCallback dispose);
enum { CMDY_SESSION_ESSENTIAL_UPDATES = 1u << 0, CMDY_SESSION_HOST_WORK_UPDATES = 1u << 1,
    CMDY_SESSION_CURSOR_CACHE_UPDATES = 1u << 2 };
/* CURSOR_CACHE_UPDATES opts into a single installation handshake. Retain offered
 * frames before returning; the host must respond to each token after installing
 * its complete backing+cursor layer transaction, or rejecting it. New terminal
 * frames pause only during this handshake, not during cache generation. Close
 * declines any unanswered offer without waiting for host delivery. RETIRED means
 * newer terminal content has actually presented; remove both cached layers as
 * one parent and report cancellation with removed=1. Never discard these updates
 * via the ordinary epoch-scoped frame filter: rejected offers still need replies.
 * Cancel before input/focus/geometry changes. The main actor owns every layer. */
uint64_t cmdy_render_session_cursor_generation(CmdyRenderSession *);
uint8_t cmdy_render_session_cursor_respond(CmdyRenderSession *, uint64_t token, uint8_t installed);
void cmdy_render_session_cursor_cancel(CmdyRenderSession *, uint64_t token, uint8_t removed, uint8_t request_draw);
/* Same ownership as create. Unknown option bits reject without taking context.
 * ESSENTIAL_UPDATES omits unsolicited intermediate ACTIONS with no host work.
 * Ordered timer/FPS/work actions, explicit replies, READY, CAPTURE, FRAME,
 * errors, capacity notifications and GPU-completion state remain delivered.
 * State mirrors update at these boundaries; INSPECT remains a FIFO snapshot.
 * HOST_WORK_UPDATES additionally omits completion-only ACTIONS and repeated
 * successful FRAME updates for the same epoch/source revision, plus stop-only
 * actions for host timers already stopped by an earlier delivered action. It includes
 * essential suppression even when ESSENTIAL_UPDATES is not separately set.
 * Failures, first success/recovery in a scope, explicit replies, timer/FPS/work,
 * READY, CAPTURE and capacity notifications remain delivered. GPU state and
 * retirement still run on the owner. OBSERVE_FRAMES (event 0/1) toggles per-frame
 * FRAME/completion and unfiltered timer delivery in FIFO order and emits the current state, including
 * an in-flight frame. It changes no rendering policy or environment. This is
 * diagnostic observation; ordinary presentation observers are independent.
 * The original create retains the complete intermediate-state callback stream. */
CmdyRenderSession *cmdy_render_session_create_with_options(const void *device,
    uint64_t format, size_t samples, uint64_t surface, double now, uint32_t options,
    CmdyRenderSessionCallback, void *context, CmdyRenderWorkerCallback dispose);
uint64_t cmdy_render_session_epoch(CmdyRenderSession *);
uint64_t cmdy_render_session_source_revision(CmdyRenderSession *);
/* Immutable terminal-owner publication; no UI/source callback is retained. */
typedef struct CmdyRenderModelInput {
    CmdyZigBufferSnapshot *snapshot;
    CmdyRenderOwnedGraphicsInput *graphics;
    uint64_t generation;
    intptr_t rows, cols, buffer_line_count, retained_row_origin, display_top_row, live_top_row;
    intptr_t cursor_row, cursor_col;
    uint32_t cursor_style;
    uint8_t cursor_hidden, alternate_buffer;
    intptr_t kitty_images, kitty_placements;
    uint32_t kitty_next_image, kitty_next_placement;
} CmdyRenderModelInput;
/* Generation increases from one per session. Retains one latest snapshot,
 * fences stale commits, and posts a coalesced allocation-free wakeup regardless
 * of control capacity. Zero rejects without changing the previous publication.
 * The worker combines content with the current UI publication. */
uint8_t cmdy_render_session_publish_model(CmdyRenderSession *, const CmdyRenderModelInput *);
/* After rejected control admission, arm one coalesced CAPACITY_AVAILABLE update
 * when the full worker queue frees space. Registration and release are atomic;
 * zero means space is already available, or the session is closed. Retry once
 * on zero before using an allocation-failure fallback. No allocation or timer
 * is needed for the notification. Availability is a hint, not a reservation;
 * another producer can consume capacity before the host handles the update.
 * Stop cancels undelivered notices; the normal callback close rules apply. */
uint8_t cmdy_render_session_wait_for_capacity(CmdyRenderSession *);
/* Commands copy their POD values and execute FIFO on the owner. Zero is explicit
 * backpressure/closed/invalid input: nothing was queued, so the host may retry.
 * Config's pipeline flags remain GPU-owned. PRESET uses event (0..5).
 * CAPTURE_FAILED must match the requested identity: event zero requests drawable
 * recovery; one reports a source failure without an automatic loop; two cancels
 * a superseded capture without reporting an error. INSPECT is a read-only FIFO
 * barrier with explicit cache residency, and never waits for GPU completion.
 * INPUT_ACTIVITY copies value (last key time in monotonic uptime seconds) and
 * value2 (nonnegative finite Float32 typing rate). It changes neither content
 * revision nor environment, and does not request a draw. The next scheduled
 * shader pass uses these scalars, including frames captured before the update.
 * Keyboard feedback and model publication retain their normal draw policies. */
uint8_t cmdy_render_session_post(CmdyRenderSession *, const CmdyRenderSessionCommand *);
uint8_t cmdy_render_session_shader(CmdyRenderSession *, const char *source, size_t length,
    uint64_t request_id, CmdyRenderScheduleEnvironment);
/* Successful submission retains both immutable inputs before returning. FRAME
 * reports the actual encoding/commit result. The caller retains its own handles.
 * Frame and target must match the identity from a current CAPTURE update. */
uint8_t cmdy_render_session_submit(CmdyRenderSession *, CmdyRenderOwnedFrameInput *,
    CmdyRenderOwnedTarget *, uint8_t cursor_blink_eligible,
    CmdyRenderScheduleEnvironment);
typedef struct {
    CmdyRenderFrameIdentity identity;
    uint64_t drawable_id;
    size_t pixel_width, pixel_height;
    double presented_time;
} CmdyRenderLayerPresentation;
typedef void (*CmdyRenderLayerPresented)(void *, const CmdyRenderLayerPresentation *);
/* Retain the frame and CAMetalLayer, then acquire and capture a fresh drawable
 * on the render worker. No MTKView drawable accessor is used. The layer must
 * keep allowsNextDrawableTimeout=true and presentsWithTransaction=false.
 * Invalidate the session before changing surface configuration; actual texture
 * size/device/format and the current frame epoch are checked before encoding.
 * Missing drawables use the existing recovery schedule. Stale packets do not
 * acquire a drawable. Close/invalidate never waits for nextDrawable.
 * A current committed drawable that reports no presentation also schedules
 * recovery. Feedback uses an independently retained, detachable relay; neither
 * close nor destroy waits for a late drawable presentation callback.
 *
 * On success the optional presentation context transfers to the packet; its
 * dispose runs exactly once, even for cancelled or unpresented frames. On
 * failure it stays caller-owned. A presentation callback can outlive the
 * session and runs on an unspecified thread, without a session pointer. Copy
 * the borrowed scalar record and use independently owned/weak host references.
 * A null callback requires null context and dispose. */
uint8_t cmdy_render_session_submit_layer(CmdyRenderSession *, CmdyRenderOwnedFrameInput *,
    const void *metal_layer, uint8_t cursor_blink_eligible, CmdyRenderScheduleEnvironment,
    CmdyRenderLayerPresented, void *presentation_context, CmdyRenderWorkerCallback presentation_dispose);
/* Opt-in immutable publication. The host must notify every content, geometry,
 * appearance, cursor and focus change with source_changed,
 * before requesting another draw. Pass the CAPTURE update's source_revision.
 * The same ownership and observer rules as submit_layer apply, but a successful
 * publication retains the inputs/layer/context until replaced, invalidated or
 * closed (and any independent presentation deliveries have drained).
 * Stationary frames reuse this owned content on the worker, copying fresh
 * identity, time and scheduler animation scalars without a host CAPTURE.
 * Live resize and nonzero scroll motion retain the normal host-capture path.
 * Epoch, revision, actual target and final commit are all checked. */
uint8_t cmdy_render_session_publish_layer(CmdyRenderSession *, CmdyRenderOwnedFrameInput *,
    uint64_t source_revision, const void *metal_layer, uint8_t cursor_blink_eligible,
    CmdyRenderScheduleEnvironment, CmdyRenderLayerPresented, void *presentation_context,
    CmdyRenderWorkerCallback presentation_dispose);
/* Advance the source token synchronously against final commit, even under
 * control-queue backpressure. Does not change the epoch or discard resident GPU
 * rows. Queue maintenance when capacity permits; every later owner control
 * also reconciles this token. The host MUST request a draw using its normal
 * retry queue after notification. Zero means closed or token exhaustion.
 * Never waits for nextDrawable, encoding or GPU completion. */
uint64_t cmdy_render_session_source_changed(CmdyRenderSession *, CmdyRenderScheduleEnvironment);
/* Reserve reset work before changing the epoch. Zero means no change (closed,
 * capacity or allocation). Success orders against final submission immediately,
 * then releases the offscreen scene and resets pacing/capture on the owner.
 * Rows rebuild on the next epoch's captured draw. CLEAR_ROWS additionally
 * releases resident rows when that control executes. Cursor/scroll continuity
 * is preserved, matching the normal resize path. */
uint64_t cmdy_render_session_invalidate(CmdyRenderSession *, CmdyRenderScheduleEnvironment);
/* Close consumes a pre-reserved ticket and never joins or waits for GPU work.
 * It can wait for the short final submission boundary. Idempotent. */
void cmdy_render_session_close(CmdyRenderSession *);
/* Stop concurrent producers first. Call off the UI/worker thread: drains all
 * controls, GPU/image completions and disposal. Returns zero for self-join. */
uint8_t cmdy_render_session_destroy(CmdyRenderSession *);
#ifdef __cplusplus
}
#endif
#endif
