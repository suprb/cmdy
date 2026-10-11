#ifndef CMDY_LEGACY_H
#define CMDY_LEGACY_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Existing internal lib_cmdy interface, now implemented by the Zig engine. */
void *cmdy_create(int32_t, int32_t);
void cmdy_free(void *);
void cmdy_feed(void *, const uint8_t *, intptr_t);
void cmdy_resize(void *, int32_t, int32_t);
int32_t cmdy_cols(void *);
int32_t cmdy_rows(void *);
int32_t cmdy_buffer_line_count(void *);
int32_t cmdy_cursor_row(void *);
int32_t cmdy_cursor_col(void *);
int32_t cmdy_live_top_row(void *);
intptr_t cmdy_line_text(void *, int32_t, char *, intptr_t);
int32_t cmdy_cell(void *, int32_t, int32_t, uint32_t *, int32_t *, uint32_t *, uint32_t *, uint32_t *);
int32_t cmdy_block_count(void *);
int32_t cmdy_block_get(void *, int32_t, int32_t *, int32_t *, int32_t *, int32_t *, int32_t *);
#ifdef __cplusplus
}
#endif
#endif
