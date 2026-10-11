#ifndef CMDY_ORDINARY_PRINTING_H
#define CMDY_ORDINARY_PRINTING_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct CmdyZigTerminal CmdyZigTerminal;
/* Callback is a synchronous continuation query, never retained. NULL permits
 * direct engine calls without an invoking parser. Status matches native ABI. */
int32_t cmdy_zig_terminal_print_ordinary_unicode(CmdyZigTerminal *, const uint8_t *, size_t,
    uint32_t first_scalar, size_t first_byte_count, void *context,
    uint8_t (*can_continue)(void *), size_t *consumed);
#ifdef __cplusplus
}
#endif
#endif
