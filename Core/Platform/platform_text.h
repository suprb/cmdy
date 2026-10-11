#ifndef CMDY_PLATFORM_TEXT_H
#define CMDY_PLATFORM_TEXT_H
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreText/CoreText.h>
#include "cmdy_render_text.h"
/* Narrow Objective-C dispatch only. Raster policy and loops belong to Zig. */
const void *cmdy_platform_text_attribute_key(unsigned index);
unsigned cmdy_platform_text_object_kind(const void *object);
long long cmdy_platform_text_number_integer(const void *object);
double cmdy_platform_text_number_double(const void *object);
const void *cmdy_platform_text_font_scaled(const void *font,double size);
double cmdy_platform_text_font_size(const void *font);
uint8_t cmdy_platform_text_font_emoji_family(const void *font);
const void *cmdy_platform_text_color_device_rgb(const void *color);
double cmdy_platform_text_color_component(const void *color,unsigned index);
CGColorRef cmdy_platform_text_color_cg(const void *color);
const void *cmdy_platform_text_white(void);
/* Snapshot helpers return immutable +1 values; resolve colors on the source's
 * owning thread and current appearance before handing them to a worker. */
const void *cmdy_platform_text_color_snapshot(const void *color);
uint8_t cmdy_platform_text_is_attributed_string(const void *object);
#endif
