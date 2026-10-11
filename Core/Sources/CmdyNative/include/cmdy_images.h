#ifndef CMDY_ZIG_IMAGES_H
#define CMDY_ZIG_IMAGES_H
#include "cmdy_buffer.h"
#ifdef __cplusplus
extern "C" {
#endif
typedef struct CmdyZigPayload CmdyZigPayload;
typedef struct CmdyZigStoredImage CmdyZigStoredImage;
typedef struct CmdyZigGraphics CmdyZigGraphics;
typedef struct CmdyZigSixel CmdyZigSixel;
typedef void (*CmdyZigImageLifetimeCallback)(void *, uint8_t);
typedef void (*CmdyZigPayloadRelease)(void *);
typedef struct {
    const uint8_t *bytes;
    size_t count;
    intptr_t width, height;
    uint8_t format; /* 0 RGBA, 1 PNG */
} CmdyZigPayloadInfo;
typedef struct {
    uint64_t identity_high, identity_low; /* Random UUID v4 bytes, big endian. */
    intptr_t pixel_width, pixel_height, col, z_index, offset_x, offset_y;
    uint32_t image_id, placement_id;
    uint8_t is_kitty, has_image_id, has_placement_id;
} CmdyZigImageInfo;
typedef struct {
    intptr_t pixel_width, pixel_height;
    uint32_t id, number;
    uint8_t has_number;
} CmdyZigStoredImageInfo;
typedef struct {
    uint32_t image_id, placement_id;
    intptr_t col, row, cols, rows, z_index, offset_x, offset_y;
    uint8_t is_virtual, is_alternate_buffer;
} CmdyZigPlacement;
typedef struct {
    intptr_t row, col;
    uint32_t image_id, placement_id;
    intptr_t placeholder_row, placeholder_col, msb;
} CmdyZigPlaceholder;
typedef struct {
    intptr_t physical_row, physical_col, placeholder_row, placeholder_col, msb;
    uint32_t foreground, underline;
    uint8_t has_underline, valid;
} CmdyZigPlaceholderState;
/* Arbitrary public host payloads are allowed. Owner is consumed on success
 * only and released after the final native payload reference, including frames. */
CmdyZigPayload *cmdy_zig_payload_create_host(uint8_t, const uint8_t *, size_t, intptr_t, intptr_t, void *, CmdyZigPayloadRelease);
CmdyZigPayload *cmdy_zig_payload_retain(CmdyZigPayload *);
void cmdy_zig_payload_release(CmdyZigPayload *);
int32_t cmdy_zig_payload_info(const CmdyZigPayload *, CmdyZigPayloadInfo *);
CmdyZigImage *cmdy_zig_image_create_host(CmdyZigPayload *, intptr_t, intptr_t, intptr_t);
CmdyZigImage *cmdy_zig_image_retain(CmdyZigImage *);
void cmdy_zig_image_release(CmdyZigImage *);
CmdyZigImage *cmdy_zig_image_snapshot(const CmdyZigImage *);
/* Payload handles and bytes are borrowed while their image is retained. */
CmdyZigPayload *cmdy_zig_image_payload(const CmdyZigImage *);
int32_t cmdy_zig_image_info(const CmdyZigImage *, CmdyZigImageInfo *);
int32_t cmdy_zig_image_set_info(CmdyZigImage *, const CmdyZigImageInfo *);
void *cmdy_zig_image_swift_context(const CmdyZigImage *);
/* Associate receives an already retained Swift context. Caller then releases
 * its native creation/getter reference. Events use the line lifetime contract. */
int32_t cmdy_zig_image_associate(CmdyZigImage *, void *, CmdyZigImageLifetimeCallback);
int32_t cmdy_zig_image_disassociate(CmdyZigImage *, void *);
CmdyZigStoredImage *cmdy_zig_stored_image_create(CmdyZigPayload *, uint32_t, uint32_t, uint8_t, intptr_t, intptr_t);
CmdyZigStoredImage *cmdy_zig_stored_image_retain(CmdyZigStoredImage *);
void cmdy_zig_stored_image_release(CmdyZigStoredImage *);
CmdyZigPayload *cmdy_zig_stored_image_payload(const CmdyZigStoredImage *);
int32_t cmdy_zig_stored_image_info(const CmdyZigStoredImage *, CmdyZigStoredImageInfo *);
void *cmdy_zig_stored_image_swift_context(const CmdyZigStoredImage *);
int32_t cmdy_zig_stored_image_associate(CmdyZigStoredImage *, void *, CmdyZigImageLifetimeCallback);
int32_t cmdy_zig_stored_image_disassociate(CmdyZigStoredImage *, void *);
CmdyZigGraphics *cmdy_zig_graphics_create(void);
/* Free standalone stores only. Terminal embedded stores belong to terminal. */
void cmdy_zig_graphics_free(CmdyZigGraphics *);
/* Scalar fields: 0 next image, 1 next placement, 2 bytes, 3 images, 4 placements. */
size_t cmdy_zig_graphics_get(const CmdyZigGraphics *, uint32_t);
/* Every nonnull image getter returns one retained reference. */
CmdyZigStoredImage *cmdy_zig_graphics_image_at(const CmdyZigGraphics *, size_t);
CmdyZigStoredImage *cmdy_zig_graphics_image(const CmdyZigGraphics *, uint32_t);
CmdyZigStoredImage *cmdy_zig_graphics_newest(const CmdyZigGraphics *, uint32_t);
int32_t cmdy_zig_graphics_placement_at(const CmdyZigGraphics *, size_t, CmdyZigPlacement *);
int32_t cmdy_zig_graphics_store(CmdyZigGraphics *, CmdyZigStoredImage *);
int32_t cmdy_zig_graphics_place(CmdyZigGraphics *, const CmdyZigPlacement *);
void cmdy_zig_graphics_delete_image(CmdyZigGraphics *, uint32_t);
void cmdy_zig_graphics_delete_placements(CmdyZigGraphics *, uint32_t);
void cmdy_zig_graphics_delete_all(CmdyZigGraphics *);
uint8_t cmdy_zig_graphics_has_placement(const CmdyZigGraphics *, uint32_t);
int32_t cmdy_zig_graphics_remove_placement(CmdyZigGraphics *, uint32_t, uint32_t, CmdyZigPlacement *);
CmdyZigSixel *cmdy_zig_sixel_create(void);
void cmdy_zig_sixel_free(CmdyZigSixel *);
int32_t cmdy_zig_sixel_feed(CmdyZigSixel *, const uint8_t *, size_t);
CmdyZigPayload *cmdy_zig_sixel_finish(CmdyZigSixel *);
void cmdy_zig_sixel_hls(intptr_t, intptr_t, intptr_t, uint8_t *);
uint8_t cmdy_zig_png_dimensions(const uint8_t *, size_t, intptr_t *, intptr_t *);
/* An owned byte result. Release with cmdy_zig_payload_release. */
CmdyZigPayload *cmdy_zig_zlib_inflated(const uint8_t *, size_t, intptr_t);
uint8_t cmdy_zig_placeholder_decode(CmdyZigPlaceholderState *, uint32_t, uint32_t, uint32_t, uint8_t,
    const uint32_t *, size_t, intptr_t, intptr_t, CmdyZigPlaceholder *);
/* The handle is a CmdyZigTerminal. Raw helper excludes parser row bookkeeping. */
int32_t cmdy_zig_terminal_handle_apc(void *, const uint8_t *, size_t, uint8_t *);
#ifdef __cplusplus
}
#endif
#endif
