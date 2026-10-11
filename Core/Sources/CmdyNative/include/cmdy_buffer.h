#ifndef CMDY_ZIG_BUFFER_H
#define CMDY_ZIG_BUFFER_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct CmdyZigLine CmdyZigLine;
typedef struct CmdyZigBuffer CmdyZigBuffer;
typedef struct CmdyZigBufferSnapshot CmdyZigBufferSnapshot;
typedef struct CmdyZigImage CmdyZigImage;
typedef struct {
    uint32_t scalar, fg, bg, underline_color;
    uint16_t link_id;
    int8_t width;
    uint8_t style, underline_kind, underline_present, reserved[2];
} CmdyZigCell;
typedef struct { CmdyZigCell cell; uint32_t cluster_offset, cluster_count; } CmdyZigStoredCell;
typedef struct { uint32_t scalar; int8_t width; uint8_t reserved[3]; } CmdyZigScalar;
typedef struct {
    intptr_t x, y;
    CmdyZigCell attribute;
    uint8_t wrap_pending, origin_mode, auto_wrap, margin_mode, reverse_wraparound;
} CmdyZigSavedCursor;
/* 0: final native owner transfers one line reference to the wrapper and drops
 * its Swift retain. 1: native ownership resumes; wrapper is retained again and
 * relinquishes its native reference. The callback may synchronously free it. */
typedef void (*CmdyZigLineLifetimeCallback)(void *, uint8_t);
CmdyZigLine *cmdy_zig_line_create(intptr_t, const CmdyZigCell *, const uint32_t *, size_t, uint8_t);
CmdyZigLine *cmdy_zig_line_retain(CmdyZigLine *);
void cmdy_zig_line_release(CmdyZigLine *);
CmdyZigLine *cmdy_zig_line_clone(const CmdyZigLine *);
CmdyZigLine *cmdy_zig_line_snapshot(const CmdyZigLine *);
/* Immutable cell/line metadata publication; images are projected separately.
 * Preserves observed revision without consuming terminal mutation stamps. */
CmdyZigLine *cmdy_zig_line_render_snapshot(const CmdyZigLine *);
/* Capture a bounded row window on the buffer's serial owner. Rows preserve
 * revision/identity, cells and complete frozen image geometry; immutable image
 * bytes are retained. No live row/image lifetime observer survives capture.
 * Empty windows are allowed at any nonnegative first row; nonempty windows
 * must lie entirely inside the buffer. Status is 0, -1 invalid, -2 allocation.
 * Capture failure does not mutate the source or consume caller ownership. */
CmdyZigBufferSnapshot *cmdy_zig_buffer_snapshot_capture(const CmdyZigBuffer *,intptr_t first,size_t count,int32_t *status);
/* Atomic references; callers must own a live reference before retaining.
 * Borrowed rows remain immutable and valid while the snapshot is retained.
 * Retaining a borrowed row separately is allowed; mutation is forbidden. */
CmdyZigBufferSnapshot *cmdy_zig_buffer_snapshot_retain(CmdyZigBufferSnapshot *);
void cmdy_zig_buffer_snapshot_release(CmdyZigBufferSnapshot *);
size_t cmdy_zig_buffer_snapshot_count(const CmdyZigBufferSnapshot *);
intptr_t cmdy_zig_buffer_snapshot_first(const CmdyZigBufferSnapshot *);
const CmdyZigLine *cmdy_zig_buffer_snapshot_line(const CmdyZigBufferSnapshot *,size_t index);
/* Copies the complete cell/extras value without creating a mutable identity.
 * UINT32_MAX cluster_offset means absent; a present empty cluster has count 0. */
CmdyZigLine *cmdy_zig_line_snapshot_from_cells(const CmdyZigStoredCell *, size_t,
    const uint32_t *, size_t, uint8_t wrapped, uint8_t render_mode, uint64_t version);
uint64_t cmdy_zig_line_identity(const CmdyZigLine *);
uint64_t cmdy_zig_line_version(const CmdyZigLine *);
intptr_t cmdy_zig_line_count(const CmdyZigLine *);
void *cmdy_zig_line_swift_context(const CmdyZigLine *);
int32_t cmdy_zig_line_associate(CmdyZigLine *, void *, CmdyZigLineLifetimeCallback);
int32_t cmdy_zig_line_disassociate(CmdyZigLine *, void *);
void cmdy_zig_line_touch(CmdyZigLine *);
/* Metadata fields: 0 wrapped, 1 wrap style(cells=0,words=1), 2 render mode. */
int32_t cmdy_zig_line_metadata(const CmdyZigLine *, uint32_t);
int32_t cmdy_zig_line_set_metadata(CmdyZigLine *, uint32_t, int32_t);
int32_t cmdy_zig_line_read(const CmdyZigLine *, intptr_t, CmdyZigCell *, const uint32_t **, size_t *, uint8_t *);
int32_t cmdy_zig_line_set(CmdyZigLine *, intptr_t, const CmdyZigCell *, const uint32_t *, size_t, uint8_t);
int32_t cmdy_zig_line_fill(CmdyZigLine *, intptr_t, intptr_t, const CmdyZigCell *, const uint32_t *, size_t, uint8_t);
int32_t cmdy_zig_line_resize(CmdyZigLine *, intptr_t, const CmdyZigCell *, const uint32_t *, size_t, uint8_t);
int32_t cmdy_zig_line_reset(CmdyZigLine *, const CmdyZigCell *, const uint32_t *, size_t, uint8_t, uint8_t);
void cmdy_zig_line_reset_metadata(CmdyZigLine *, uint8_t);
int32_t cmdy_zig_line_write_ascii(CmdyZigLine *, intptr_t, const uint8_t *, size_t, const CmdyZigCell *);
int32_t cmdy_zig_line_write_unicode(CmdyZigLine *, intptr_t, const CmdyZigScalar *, size_t, const CmdyZigCell *, const CmdyZigCell *);
int32_t cmdy_zig_line_append_scalar(CmdyZigLine *, intptr_t, uint32_t, int8_t);
int32_t cmdy_zig_line_edit(CmdyZigLine *, intptr_t, intptr_t, intptr_t, uint8_t, const CmdyZigCell *, const uint32_t *, size_t, uint8_t);
int32_t cmdy_zig_line_copy_columns(CmdyZigLine *, const CmdyZigLine *, intptr_t, intptr_t);
intptr_t cmdy_zig_line_used_length(const CmdyZigLine *, uint8_t);
int32_t cmdy_zig_line_prepare_read(CmdyZigLine *);
/* Borrowed until this line's next mutation; prepare_read must precede cells. */
const CmdyZigStoredCell *cmdy_zig_line_cells(const CmdyZigLine *, size_t *);
const uint32_t *cmdy_zig_line_extras(const CmdyZigLine *, size_t *);
/* Image count -1 represents nil, zero represents an explicitly empty list. */
intptr_t cmdy_zig_line_image_count(const CmdyZigLine *);
CmdyZigImage *cmdy_zig_line_image_get(const CmdyZigLine *, size_t);
int32_t cmdy_zig_line_set_images(CmdyZigLine *, CmdyZigImage *const *, size_t, uint8_t);

CmdyZigBuffer *cmdy_zig_buffer_create(intptr_t, intptr_t, uint8_t, intptr_t);
/* Free standalone buffers only. Terminal-embedded buffers belong to terminal. */
void cmdy_zig_buffer_free(CmdyZigBuffer *);
/* Cold serial-owner maintenance only; never called by feed/scroll. Both row
 * visits (at most 64) and inspected columns (at most 8192) are bounded. */
typedef struct {
    intptr_t next_absolute_row;
    size_t visited;
    size_t compacted;
    uint8_t complete;
    uint8_t reserved[7];
} CmdyZigHistoryMaintenance;
int32_t cmdy_zig_buffer_compact_history(CmdyZigBuffer *, intptr_t, size_t,
                                      CmdyZigHistoryMaintenance *);
/* Scalar fields: 0 x,1 y,2 yBase,3 yDisp,4 cols,5 rows,6 maxScrollback,
 * 7 scrollTop,8 scrollBottom,9 marginLeft,10 marginRight,11 wrapPending,
 * 12 droppedLines,13 hasScrollback,14 lineCount,15 backingSlots,16 prefix. */
intptr_t cmdy_zig_buffer_get(const CmdyZigBuffer *, uint32_t);
int32_t cmdy_zig_buffer_set(CmdyZigBuffer *, uint32_t, intptr_t);
/* Every nonnull line returned owns one reference. */
CmdyZigLine *cmdy_zig_buffer_line(const CmdyZigBuffer *, intptr_t);
CmdyZigLine *cmdy_zig_buffer_ghost_line(CmdyZigBuffer *, intptr_t);
intptr_t cmdy_zig_buffer_ghost_keys(const CmdyZigBuffer *, intptr_t *, size_t);
void cmdy_zig_buffer_clear_ghosts(CmdyZigBuffer *);
int32_t cmdy_zig_buffer_saved_cursor(const CmdyZigBuffer *, CmdyZigSavedCursor *);
int32_t cmdy_zig_buffer_set_saved_cursor(CmdyZigBuffer *, const CmdyZigSavedCursor *);
intptr_t cmdy_zig_buffer_tab_stops(const CmdyZigBuffer *, intptr_t *, size_t);
int32_t cmdy_zig_buffer_reset_tabs(CmdyZigBuffer *);
int32_t cmdy_zig_buffer_set_tab(CmdyZigBuffer *, intptr_t);
void cmdy_zig_buffer_clear_tab(CmdyZigBuffer *, intptr_t);
void cmdy_zig_buffer_clear_tabs(CmdyZigBuffer *);
intptr_t cmdy_zig_buffer_next_tab(const CmdyZigBuffer *, intptr_t, uint8_t);
intptr_t cmdy_zig_buffer_previous_tab(const CmdyZigBuffer *, intptr_t);
/* Scroll operation: 0 LF/up,1 SU,2 RI/down,3 IL,4 DL. */
int32_t cmdy_zig_buffer_scroll(CmdyZigBuffer *, uint32_t, intptr_t, intptr_t, const CmdyZigCell *, const uint32_t *, size_t, uint8_t, uint8_t, uint8_t);
int32_t cmdy_zig_buffer_resize(CmdyZigBuffer *, intptr_t, intptr_t);
int32_t cmdy_zig_buffer_reset(CmdyZigBuffer *);
void cmdy_zig_buffer_clear_scrollback(CmdyZigBuffer *);
int32_t cmdy_zig_buffer_append_line(CmdyZigBuffer *, CmdyZigLine *);
int32_t cmdy_zig_buffer_replace_lines(CmdyZigBuffer *, CmdyZigLine *const *, size_t);
int32_t cmdy_zig_buffer_set_geometry(CmdyZigBuffer *, intptr_t, intptr_t);
void cmdy_zig_buffer_note_dropped(CmdyZigBuffer *, intptr_t);
int32_t cmdy_zig_buffer_replace_content(CmdyZigBuffer *, CmdyZigLine *const *, size_t, intptr_t, intptr_t, intptr_t, intptr_t, intptr_t, intptr_t, intptr_t);
#ifdef __cplusplus
}
#endif
#endif
