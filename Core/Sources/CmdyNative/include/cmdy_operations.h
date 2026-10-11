#ifndef CMDY_OPERATIONS_H
#define CMDY_OPERATIONS_H
#include <stddef.h>
#include <stdint.h>
#include "cmdy_buffer.h"
typedef struct CmdyZigTerminal CmdyZigTerminal;
#ifdef __cplusplus
extern "C" {
#endif
int32_t cmdy_zig_terminal_operation(CmdyZigTerminal *, uint32_t,
    intptr_t, intptr_t, intptr_t, const intptr_t *, size_t);
int32_t cmdy_zig_terminal_insert_cell(CmdyZigTerminal *, const CmdyZigCell *, const uint32_t *, size_t, uint8_t);
int32_t cmdy_zig_terminal_cell_edit(CmdyZigTerminal *, intptr_t, intptr_t, intptr_t, intptr_t,
    uint8_t, void *, void (*)(void *), uint8_t *);
size_t cmdy_zig_terminal_witness_count(CmdyZigTerminal *, uint32_t);
/* Result is retained. Kinds 1-4 are Line, 5 is LineImage. */
void *cmdy_zig_terminal_witness(CmdyZigTerminal *, uint32_t, size_t);
#ifdef __cplusplus
}
#endif
#endif
