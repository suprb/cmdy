/* cmdy.h — INTERNAL lib_cmdy C ABI experiment. NOT PUBLIC OR SUPPORTED.
 * No compatibility or binary-stability promise.
 *
 * CmdyCore embedded: create a terminal, feed it bytes, read the grid
 * and the semantic blocks back. Single-threaded by contract.
 */
#ifndef CMDY_H
#define CMDY_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void *cmdy_t;

/* Returns NULL for non-positive or unreasonably large dimensions. */
cmdy_t cmdy_create(int32_t cols, int32_t rows);
/* All functions tolerate a NULL handle; queries return -1. */
void      cmdy_free(cmdy_t t);
void      cmdy_feed(cmdy_t t, const uint8_t *bytes, size_t len);
void      cmdy_resize(cmdy_t t, int32_t cols, int32_t rows);

int32_t cmdy_cols(cmdy_t t);
int32_t cmdy_rows(cmdy_t t);
int32_t cmdy_buffer_line_count(cmdy_t t);
int32_t cmdy_cursor_row(cmdy_t t);   /* absolute (scrollback included) */
int32_t cmdy_cursor_col(cmdy_t t);
int32_t cmdy_live_top_row(cmdy_t t); /* first row of the live screen */

/* Right-trimmed UTF-8 row text; returns bytes written (excl. NUL), -1 on
 * a bad row. */
long cmdy_line_text(cmdy_t t, int32_t row, char *out, size_t capacity);

/* One cell. Colors are packed 0xTTRRGGBB: TT 0 = default, 1 = indexed
 * (low byte), 2 = truecolor, 3 = inverted default. Returns 0, or -1 when
 * out of range. */
int32_t cmdy_cell(cmdy_t t, int32_t row, int32_t col,
                     uint32_t *codepoint, int32_t *width,
                     uint32_t *fg, uint32_t *bg, uint32_t *style);

/* Blocks: OSC 133 command regions, the semantic feature. */
int32_t cmdy_block_count(cmdy_t t);
int32_t cmdy_block_get(cmdy_t t, int32_t index,
                          int32_t *prompt_row, int32_t *command_row,
                          int32_t *end_row, int32_t *exit_code,
                          int32_t *running);

#ifdef __cplusplus
}
#endif
#endif /* CMDY_H */
