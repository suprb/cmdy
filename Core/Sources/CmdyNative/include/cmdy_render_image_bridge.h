#ifndef CMDY_RENDER_IMAGE_BRIDGE_H
#define CMDY_RENDER_IMAGE_BRIDGE_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef void (*CmdyImageBridgeRelease)(void *);
/* Main-thread bounded identity cache. Put takes ownership of the host context. */
void *cmdy_image_bridge_cached(const uint8_t identity[16]);
uint8_t cmdy_image_bridge_cache(const uint8_t identity[16],void *context,CmdyImageBridgeRelease release);
void cmdy_image_bridge_clear(void);
/* Returns a +1 NSImage. Invalid payloads produce the contract's transparent pixel. */
const void *cmdy_image_bridge_decode(uint8_t kind,const uint8_t *,size_t,intptr_t width,intptr_t height,intptr_t declared_width,intptr_t declared_height);
#ifdef __cplusplus
}
#endif
#endif
