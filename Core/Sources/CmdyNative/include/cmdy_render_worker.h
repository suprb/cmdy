#ifndef CMDY_RENDER_WORKER_H
#define CMDY_RENDER_WORKER_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct CmdyRenderWorker CmdyRenderWorker;
typedef struct CmdyRenderCompletion CmdyRenderCompletion;
typedef void (*CmdyRenderWorkerCallback)(void *context);
/* Invoke body(context) synchronously, exactly once. Used for platform pools. */
typedef void (*CmdyRenderWorkerScope)(CmdyRenderWorkerCallback body,void *context);
typedef void (*CmdyRenderCompletionRun)(void *context,CmdyRenderWorker *,uint32_t result);
typedef void (*CmdyRenderWorkerRun)(void *context, CmdyRenderWorker *, uint64_t epoch);
typedef void (*CmdyRenderWorkerDispose)(void *context, uint32_t reason);
enum {
    CMDY_RENDER_WORKER_EXECUTED = 0,
    CMDY_RENDER_WORKER_SUPERSEDED = 1,
    CMDY_RENDER_WORKER_INVALIDATED = 2,
    CMDY_RENDER_WORKER_STOPPED = 3
};
CmdyRenderWorker *cmdy_render_worker_create(void);
/* The optional scope encloses run+dispose and dropped-frame disposal. It can
 * execute on a producer or worker thread; it must never retain body/context. */
CmdyRenderWorker *cmdy_render_worker_create_with_scope(CmdyRenderWorkerScope);
enum { CMDY_RENDER_COMPLETION_READY = 0, CMDY_RENDER_COMPLETION_CANCELLED = 1 };
/* Reserve before starting asynchronous work. At most 1024 tickets may be
 * outstanding per worker. Failure leaves context caller-owned; do not launch
 * that work. Success owns context until run then dispose execute on the worker.
 * Every ticket MUST eventually be consumed exactly once by complete or cancel.
 * Either operation allocates nothing and remains valid after stop/invalidate.
 * Publication order is FIFO with frame submissions; replacing the waiting frame
 * moves it to the tail. Completions are never superseded or invalidated.
 * Cancellation also runs the callback with CANCELLED before disposing it.
 * No callback may destroy/join its worker. */
CmdyRenderCompletion *cmdy_render_worker_prepare_completion(CmdyRenderWorker *,void *context,
    CmdyRenderCompletionRun,CmdyRenderWorkerCallback dispose);
/* These consume the ticket. Do not access it again; it may already be freed
 * before the call returns. External result writes must precede publication. */
void cmdy_render_worker_complete(CmdyRenderCompletion *);
void cmdy_render_worker_cancel_completion(CmdyRenderCompletion *);
size_t cmdy_render_worker_outstanding_completions(CmdyRenderWorker *);
/* A surface epoch, or zero when stopped. This query is not a commit fence. */
uint64_t cmdy_render_worker_epoch(CmdyRenderWorker *);
/* One active frame plus at most one waiting frame. On success context is owned
 * until dispose runs exactly once. On failure caller retains ownership.
 * Callbacks never run under the mailbox lock. Dispose may run on either thread.
 * Packets must contain retained immutable input, with no borrowed host buffers. */
uint8_t cmdy_render_worker_submit(CmdyRenderWorker *, uint64_t epoch, void *context,
                                 CmdyRenderWorkerRun, CmdyRenderWorkerDispose);
uint64_t cmdy_render_worker_invalidate(CmdyRenderWorker *);
void cmdy_render_worker_stop(CmdyRenderWorker *);
/* Stop producers first. One external owner joins; returns zero for self-join
 * without freeing the worker. No caller may access a successfully destroyed
 * worker. Reserved completions keep the worker running while frames are stopped.
 * Active callbacks and every ticket's run/dispose finish before destroy returns.
 * A producer that forgets to complete/cancel its ticket prevents shutdown. */
uint8_t cmdy_render_worker_destroy(CmdyRenderWorker *);
#ifdef __cplusplus
}
#endif
#endif
