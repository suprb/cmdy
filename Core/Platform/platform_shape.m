#import <AppKit/AppKit.h>
#include "platform_shape.h"
const void *cmdy_platform_shape_color_srgb(const void *color) {
    return (__bridge_retained const void *)[(__bridge NSColor *)color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
}
const void *cmdy_platform_shape_color_create(double r,double g,double b,double a) {
    return (__bridge_retained const void *)[NSColor colorWithSRGBRed:r green:g blue:b alpha:a];
}
const void *cmdy_platform_shape_font_traits(const void *font,unsigned long traits) {
    return (__bridge_retained const void *)[NSFontManager.sharedFontManager convertFont:(__bridge NSFont *)font toHaveTrait:(NSFontTraitMask)traits];
}
double cmdy_platform_shape_font_metric(const void *font,unsigned metric) {
    NSFont *value = (__bridge NSFont *)font;
    switch (metric) { case 0:return value.ascender; case 1:return value.descender; case 2:return value.leading; default:return 0; }
}
const void *cmdy_platform_shape_image(CGImageRef image,double width,double height) {
    NSSize size=NSMakeSize(width,height);
    return (__bridge_retained const void *)(image ? [[NSImage alloc] initWithCGImage:image size:size] : [[NSImage alloc] initWithSize:size]);
}
