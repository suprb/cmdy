// Headless cache instrumentation and pixel oracle. No windows, input or PTY.
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <CoreText/CoreText.h>
#include "cmdy_render_gpu.h"
#include "platform_gpu.h"
#include <stdatomic.h>
#include <stdlib.h>

extern const void *glyph_original_font_name(const void *);
extern uint64_t glyph_original_hash(const void *);
extern uint8_t glyph_original_equal(const void *, const void *);
extern void *glyph_original_retain(const void *);
extern void glyph_original_release(const void *);
static atomic_ullong counts[5];
static bool collide;
static const void *watched_font;

const void *cmdy_gpu_apple_font_name(const void *font) {
    atomic_fetch_add(&counts[0], 1); return glyph_original_font_name(font);
}
uint64_t cmdy_gpu_apple_hash(const void *value) {
    atomic_fetch_add(&counts[1], 1); return collide ? 7 : glyph_original_hash(value);
}
uint8_t cmdy_gpu_apple_equal(const void *a, const void *b) {
    atomic_fetch_add(&counts[2], 1); return glyph_original_equal(a, b);
}
void *cmdy_gpu_apple_retain(const void *value) {
    if (value && value == watched_font) atomic_fetch_add(&counts[3], 1);
    return glyph_original_retain(value);
}
void cmdy_gpu_apple_release(const void *value) {
    if (value && value == watched_font) atomic_fetch_add(&counts[4], 1);
    glyph_original_release(value);
}
void glyph_test_reset(const void *font) {
    watched_font = font; for (unsigned i = 0; i < 5; i++) atomic_store(&counts[i], 0);
}
uint64_t glyph_test_count(unsigned kind) { return kind < 5 ? atomic_load(&counts[kind]) : 0; }
void glyph_test_collide(uint8_t value) { collide = value != 0; }
const void *glyph_test_device(void) { return (__bridge_retained const void *)MTLCreateSystemDefaultDevice(); }
const void *glyph_test_font(double size, unsigned variant) {
    CGAffineTransform transform = CGAffineTransformMake(1.7, 0, 0.25, 1, 0, 0);
    if (variant == 0 || variant == 1)
        return CTFontCreateWithName(CFSTR("Menlo"), size, variant == 1 ? &transform : NULL);
    if (variant == 4) return CTFontCreateWithName(CFSTR("AppleColorEmoji"), size, NULL);
    CTFontRef base = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, size, NULL);
    if (!base) return NULL;
    CFArrayRef axes = CTFontCopyVariationAxes(base);
    if (!axes || CFArrayGetCount(axes) == 0) { if (axes) CFRelease(axes); CFRelease(base); return NULL; }
    CFDictionaryRef axis = CFArrayGetValueAtIndex(axes, 0);
    id identifier = (__bridge id)CFDictionaryGetValue(axis, kCTFontVariationAxisIdentifierKey);
    id value = (__bridge id)CFDictionaryGetValue(axis,
        variant == 2 ? kCTFontVariationAxisMinimumValueKey : kCTFontVariationAxisMaximumValueKey);
    NSDictionary *attributes = @{(__bridge NSString *)kCTFontVariationAttribute: @{identifier: value}};
    CTFontDescriptorRef descriptor = CTFontCopyFontDescriptor(base);
    CTFontDescriptorRef changed = CTFontDescriptorCreateCopyWithAttributes(descriptor, (__bridge CFDictionaryRef)attributes);
    CTFontRef result = CTFontCreateWithFontDescriptor(changed, size, NULL);
    CFRelease(changed); CFRelease(descriptor); CFRelease(axes); CFRelease(base);
    return result;
}
uint16_t glyph_test_glyph(const void *font, uint32_t code) {
    UniChar characters[2]; CGGlyph glyphs[2] = {0}; CFIndex length = 1;
    if (code <= 0xffff) characters[0] = (UniChar)code;
    else { code -= 0x10000; characters[0] = (UniChar)(0xd800 + (code >> 10));
        characters[1] = (UniChar)(0xdc00 + (code & 1023)); length = 2; }
    if (!CTFontGetGlyphsForCharacters((CTFontRef)font, characters, glyphs, length)) return 0;
    return glyphs[0] ? glyphs[0] : glyphs[1];
}
static uint8_t *pixels(const void *texture, size_t x, size_t y, size_t w, size_t h, size_t page, size_t bpp) {
    id<MTLTexture> value = (__bridge id<MTLTexture>)texture;
    uint8_t *result = malloc(w * h * bpp); if (!result) return NULL;
    [value getBytes:result bytesPerRow:w * bpp bytesPerImage:w * h * bpp
        fromRegion:MTLRegionMake2D(x, y, w, h) mipmapLevel:0 slice:page];
    return result;
}
uint8_t glyph_test_line_pixels(const void *texture, const CmdyRenderRect *rect, const void *font, uint16_t glyph) {
    CmdyRenderGlyphBitmap *bitmap = cmdy_render_glyph_rasterize(font, glyph); if (!bitmap) return 0;
    CmdyRenderGlyphBitmapView view; cmdy_render_glyph_bitmap_view(bitmap, &view);
    bool match = !view.is_color && rect->width == view.width && rect->height == view.height;
    uint8_t *bytes = match ? pixels(texture, rect->x, rect->y, rect->width, rect->height, 0, 1) : NULL;
    if (!bytes) match = false;
    if (match) for (intptr_t y = 0; y < view.height; y++) for (intptr_t x = 0; x < view.width; x++)
        if (bytes[y * view.width + x] != view.bytes[((view.height - y - 1) * view.width + x) * 4 + 3]) match = false;
    free(bytes); cmdy_render_glyph_bitmap_free(bitmap); return match;
}
uint8_t glyph_test_compatibility_pixels(const void *texture, const CmdyGpuGlyphEntry *entry,
    const void *font, uint16_t glyph, unsigned padding) {
    CmdyRenderGlyphBitmap *bitmap = cmdy_render_glyph_rasterize(font, glyph); if (!bitmap) return 0;
    CmdyRenderGlyphBitmapView view; cmdy_render_glyph_bitmap_view(bitmap, &view);
    size_t bpp = view.is_color ? 4 : 1;
    bool match = entry->bitmap_width == view.width && entry->bitmap_height == view.height &&
        entry->bearing_x == view.bearing_x && entry->bearing_y == view.bearing_y && entry->is_color == view.is_color &&
        entry->width == view.width + 2 * padding && entry->height == view.height + 2 * padding;
    uint8_t *bytes = match ? pixels(texture, entry->x, entry->y, entry->width, entry->height, entry->page, bpp) : NULL;
    if (!bytes) match = false;
    if (match) for (intptr_t y = 0; y < entry->height; y++) for (intptr_t x = 0; x < entry->width; x++)
        for (size_t channel = 0; channel < bpp; channel++) {
            uint8_t expected = (x < padding || y < padding || x >= view.width + padding || y >= view.height + padding)
                ? 0 : view.bytes[((y - padding) * view.width + x - padding) * bpp + channel];
            if (bytes[(y * entry->width + x) * bpp + channel] != expected) match = false;
        }
    free(bytes); cmdy_render_glyph_bitmap_free(bitmap); return match;
}
