#ifndef CMDY_NATIVE_H
#define CMDY_NATIVE_H
#include <stddef.h>
#include <stdint.h>
#include "cmdy_buffer.h"
#include "cmdy_parser.h"
#include "cmdy_ordinary_printing.h"
#include "cmdy_operations.h"
#include "cmdy_images.h"
#include "cmdy_blocks.h"
#include "cmdy_legacy.h"
#include "cmdy_render_text.h"
#include "cmdy_render_gpu.h"
#include "cmdy_render_schedule.h"
#include "cmdy_render_shape.h"
#include "cmdy_render_image_bridge.h"
#include "cmdy_render_contract.h"
#include "cmdy_render_trace.h"
#include "cmdy_render_worker.h"
#include "cmdy_render_input.h"
#include "cmdy_render_frame_input.h"
#include "cmdy_render_session.h"
#ifdef __cplusplus
extern "C" {
#endif

typedef struct CmdyZigTerminal CmdyZigTerminal;
typedef struct CmdyZigSpan { intptr_t first, last; } CmdyZigSpan;
typedef struct CmdyZigEvent {
    uint32_t kind;
    intptr_t argument, argument2;
    const uint8_t *bytes;
    size_t length;
    const uint8_t *bytes2;
    size_t length2;
    void *object;
} CmdyZigEvent;
typedef struct CmdyZigHost {
    void *context;
    void (*event)(void *, const CmdyZigEvent *);
    double (*now)(void *);
} CmdyZigHost;
enum {
    CMDY_ZIG_OK = 0, CMDY_ZIG_OUT_OF_MEMORY = 1,
    CMDY_ZIG_INVALID_INPUT = 2, CMDY_ZIG_DISPOSED = 3,
    CMDY_ZIG_ENGINE_ERROR = 4
};
enum {
    CMDY_ZIG_EVENT_SEND=1, CMDY_ZIG_EVENT_TITLE, CMDY_ZIG_EVENT_DIRECTORY,
    CMDY_ZIG_EVENT_BELL, CMDY_ZIG_EVENT_CLIPBOARD_WRITE, CMDY_ZIG_EVENT_CONTENT_CHANGED,
    CMDY_ZIG_EVENT_WILL_REFLOW, CMDY_ZIG_EVENT_DID_REFLOW, CMDY_ZIG_EVENT_NOTIFICATION,
    CMDY_ZIG_EVENT_OSC, CMDY_ZIG_EVENT_BLOCKS_CHANGED, CMDY_ZIG_EVENT_COMMAND_FINISHED,
    CMDY_ZIG_EVENT_RECORD_INPUT, CMDY_ZIG_EVENT_FAILED_COMMAND
};
enum {
    CMDY_ZIG_ALTERNATE=1, CMDY_ZIG_APPLICATION_CURSOR, CMDY_ZIG_ORIGIN,
    CMDY_ZIG_AUTO_WRAP, CMDY_ZIG_INSERT, CMDY_ZIG_LINE_FEED,
    CMDY_ZIG_CURSOR_HIDDEN, CMDY_ZIG_REVERSE_VIDEO, CMDY_ZIG_BRACKETED_PASTE,
    CMDY_ZIG_FOCUS_REPORTING, CMDY_ZIG_CURSOR_BLINK, CMDY_ZIG_SYNCHRONIZED_UPDATES,
    CMDY_ZIG_ALLOW_80_TO_132, CMDY_ZIG_MARGIN_MODE, CMDY_ZIG_REVERSE_WRAP,
    CMDY_ZIG_WRITING_HOST_MESSAGE, CMDY_ZIG_RECORDING, CMDY_ZIG_GL_LEVEL,
    CMDY_ZIG_CURSOR_STYLE, CMDY_ZIG_MOUSE_MODE, CMDY_ZIG_MOUSE_PROTOCOL,
    CMDY_ZIG_ACTIVE_LINK, CMDY_ZIG_KEYBOARD_FLAGS, CMDY_ZIG_BLOCKS_DROPPED_CHECKPOINT,
    CMDY_ZIG_COALESCE_ASCII, CMDY_ZIG_DECODE_CONTIGUOUS_UTF8, CMDY_ZIG_HAS_FAILED_COMMAND_PROVIDER
};

CmdyZigTerminal *cmdy_zig_terminal_create(intptr_t cols, intptr_t rows, intptr_t scrollback);
/* Safe during a host callback: disposal waits for the outer native call. */
void cmdy_zig_terminal_free(CmdyZigTerminal *);
int32_t cmdy_zig_terminal_set_host(CmdyZigTerminal *, const CmdyZigHost *);
/* Defaults to enabled. Suppresses only BLOCKS_CHANGED delivery; state updates
 * and all other events retain their original boundaries. Safe during callbacks. */
int32_t cmdy_zig_terminal_set_block_change_events(CmdyZigTerminal *, uint8_t enabled);
int32_t cmdy_zig_terminal_set_parser_delegate(CmdyZigTerminal *, const CmdyZigParserDelegateRoute *);
int32_t cmdy_zig_terminal_feed(CmdyZigTerminal *, const uint8_t *, size_t);
int32_t cmdy_zig_terminal_resize(CmdyZigTerminal *, intptr_t, intptr_t);
int32_t cmdy_zig_terminal_host_message(CmdyZigTerminal *, const uint8_t *, size_t);
int32_t cmdy_zig_terminal_scroll_viewport(CmdyZigTerminal *, intptr_t);
intptr_t cmdy_zig_terminal_get_int(CmdyZigTerminal *, uint32_t);
int32_t cmdy_zig_terminal_set_int(CmdyZigTerminal *, uint32_t, intptr_t);
void cmdy_zig_terminal_get_pen(CmdyZigTerminal *, CmdyZigCell *);
int32_t cmdy_zig_terminal_set_pen(CmdyZigTerminal *, const CmdyZigCell *);
/* Buffer 0 is active, 1 normal, 2 alternate. The caller keeps terminal alive. */
void *cmdy_zig_terminal_buffer(CmdyZigTerminal *, uint32_t);
void *cmdy_zig_terminal_parser(CmdyZigTerminal *);
void *cmdy_zig_terminal_blocks(CmdyZigTerminal *);
void *cmdy_zig_terminal_graphics(CmdyZigTerminal *);
uint8_t cmdy_zig_terminal_dirty(CmdyZigTerminal *, uint8_t consume, CmdyZigSpan *);
void cmdy_zig_terminal_set_dirty(CmdyZigTerminal *, const CmdyZigSpan *);
void cmdy_zig_terminal_mark_viewport(CmdyZigTerminal *);
const uint8_t *cmdy_zig_terminal_title(CmdyZigTerminal *, size_t *);
int32_t cmdy_zig_terminal_set_title(CmdyZigTerminal *, const uint8_t *, size_t);
const uint8_t *cmdy_zig_terminal_link(CmdyZigTerminal *, uint16_t, size_t *);
const uint8_t *cmdy_zig_terminal_decrqss(CmdyZigTerminal *, size_t *);
/* Direct delegate operations preserve the public VTParserDelegate API. */
enum { CMDY_ZIG_PRINT=1, CMDY_ZIG_ASCII, CMDY_ZIG_ASCII_CRLF, CMDY_ZIG_ASCII_LINES,
    CMDY_ZIG_EXECUTE, CMDY_ZIG_CSI, CMDY_ZIG_ESC, CMDY_ZIG_OSC,
    CMDY_ZIG_DCS_HOOK, CMDY_ZIG_DCS_PUT, CMDY_ZIG_DCS_UNHOOK, CMDY_ZIG_APC,
    CMDY_ZIG_FULL_RESET, CMDY_ZIG_SOFT_RESET, CMDY_ZIG_EXECUTE_CONTROL,
    CMDY_ZIG_SYNCHRONIZE_BLOCKS, CMDY_ZIG_SEND_RESPONSE, CMDY_ZIG_DISPATCH_ESC };
int32_t cmdy_zig_terminal_dispatch(CmdyZigTerminal *, uint32_t operation, intptr_t argument,
    const intptr_t *params, size_t param_count, const uint8_t *collect, size_t collect_count,
    const uint8_t *bytes, size_t byte_count);
int8_t cmdy_zig_scalar_width(uint32_t);
uint8_t cmdy_zig_scalar_property(uint32_t, uint32_t);
int32_t cmdy_zig_terminal_mouse(CmdyZigTerminal *, intptr_t button, uint8_t pressed, uint8_t motion,
    intptr_t modifiers, intptr_t col, intptr_t row, uint8_t *reported);
uint8_t cmdy_zig_scalar_vs16_base(uint32_t);
uint32_t cmdy_zig_engine_abi_version(void);
uint32_t cmdy_native_engine_abi_version(void);
const char *cmdy_native_engine_source_key(void);
const char *cmdy_native_engine_build_mode(void);
#ifdef __cplusplus
}
#endif
#endif
