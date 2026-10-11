#ifndef CMDY_PARSER_H
#define CMDY_PARSER_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct CmdyZigParser CmdyZigParser;
typedef struct CmdyZigParserEvent {
    uint32_t kind;
    intptr_t argument;
    const intptr_t *params;
    size_t param_count;
    const uint8_t *collect;
    size_t collect_count;
    const uint8_t *bytes;
    size_t byte_count;
    size_t first_byte_count;
    size_t *consumed;
} CmdyZigParserEvent;
typedef void (*CmdyZigParserCallback)(void *, const CmdyZigParserEvent *);
typedef struct CmdyZigParserDelegateRoute {
    void *context;
    CmdyZigParserCallback event;
    /* 0: native owner. 1: external delegate, including a NULL/nil delegate. */
    uint8_t use_external;
} CmdyZigParserDelegateRoute;
enum {
    CMDY_ZIG_PARSER_PRINT=1, CMDY_ZIG_PARSER_ASCII,
    CMDY_ZIG_PARSER_ASCII_CRLF, CMDY_ZIG_PARSER_ASCII_LINES,
    CMDY_ZIG_PARSER_EXECUTE, CMDY_ZIG_PARSER_CSI, CMDY_ZIG_PARSER_ESC,
    CMDY_ZIG_PARSER_OSC, CMDY_ZIG_PARSER_DCS_HOOK, CMDY_ZIG_PARSER_DCS_PUT,
    CMDY_ZIG_PARSER_DCS_UNHOOK, CMDY_ZIG_PARSER_APC, CMDY_ZIG_PARSER_UNICODE
};
enum {
    CMDY_ZIG_PARSER_COALESCE_ASCII=1, CMDY_ZIG_PARSER_DECODE_UTF8,
    CMDY_ZIG_PARSER_BATCH_UNICODE, CMDY_ZIG_PARSER_COALESCE_CSI
};
enum {
    CMDY_ZIG_PARSER_GROUND, CMDY_ZIG_PARSER_ESCAPE,
    CMDY_ZIG_PARSER_ESCAPE_INTERMEDIATE, CMDY_ZIG_PARSER_CSI_ENTRY,
    CMDY_ZIG_PARSER_CSI_PARAM, CMDY_ZIG_PARSER_CSI_INTERMEDIATE,
    CMDY_ZIG_PARSER_CSI_IGNORE, CMDY_ZIG_PARSER_OSC_STRING,
    CMDY_ZIG_PARSER_DCS_ENTRY, CMDY_ZIG_PARSER_DCS_PARAM,
    CMDY_ZIG_PARSER_DCS_INTERMEDIATE, CMDY_ZIG_PARSER_DCS_PASSTHROUGH,
    CMDY_ZIG_PARSER_DCS_IGNORE, CMDY_ZIG_PARSER_SOS_PM_STRING,
    CMDY_ZIG_PARSER_APC_STRING
};

CmdyZigParser *cmdy_zig_parser_create(void);
/* raw is the pointer from cmdy_zig_terminal_parser. The caller retains its
 * terminal owner until this adapter is freed. Free never destroys raw. */
CmdyZigParser *cmdy_zig_parser_borrow(void *raw);
/* Disposal requested from a callback completes after the outer feed returns. */
void cmdy_zig_parser_free(CmdyZigParser *);
/* Status values match CMDY_ZIG_OK/OUT_OF_MEMORY/INVALID_INPUT/DISPOSED/ENGINE_ERROR. */
int32_t cmdy_zig_parser_reset(CmdyZigParser *);
uint32_t cmdy_zig_parser_state(const CmdyZigParser *);
uint8_t cmdy_zig_parser_can_continue_unicode(const CmdyZigParser *);
int32_t cmdy_zig_parser_get_option(const CmdyZigParser *, uint32_t option);
int32_t cmdy_zig_parser_set_option(CmdyZigParser *, uint32_t option, uint8_t enabled);
/* Event slices are immutable through nested feed/reset calls and borrowed only
 * until callback return. A receiver retaining a slice must copy its contents.
 * UNICODE supplies the first decoded scalar and the remaining input bytes.
 * consumed starts at first_byte_count; an engine callback may increase it up
 * to byte_count after checking its invoking parser's continuation state. */
int32_t cmdy_zig_parser_feed(CmdyZigParser *, const uint8_t *, size_t,
    void *context, CmdyZigParserCallback);

#ifdef __cplusplus
}
#endif
#endif
