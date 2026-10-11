#ifndef CMDY_RENDER_TRACE_H
#define CMDY_RENDER_TRACE_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Opt-in process singleton. Environment is read once; disabled calls never
 * sample the clock, allocate a record, or initialize the serial writer. */
typedef struct CmdyRenderTraceField { const char *name; intptr_t value; } CmdyRenderTraceField;
uint8_t cmdy_render_trace_enabled(void);
uint64_t cmdy_render_trace_now(void);
void cmdy_render_trace_record(const char *event,uint64_t started,const CmdyRenderTraceField *,size_t count);
/* Value adapters can capture the endpoint immediately after their lazy fields
 * expression, before marshaling C strings. Native owns reservation and output. */
void cmdy_render_trace_record_ended(const char *event,uint64_t started,uint64_t ended,const CmdyRenderTraceField *,size_t count);
/* Deterministic qualification seam: drain an existing writer, never create it.
 * Call only from outside the renderer's private trace queue. */
void cmdy_render_trace_flush(void);
#ifdef __cplusplus
}
#endif
#endif
