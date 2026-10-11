#import <AppKit/AppKit.h>
#include "platform_text.h"
const void *cmdy_platform_text_attribute_key(unsigned index) {
    switch (index) {
        case 0: return (__bridge const void *)NSFontAttributeName;
        case 1: return (__bridge const void *)NSForegroundColorAttributeName;
        case 2: return (__bridge const void *)NSBackgroundColorAttributeName;
        case 3: return (__bridge const void *)@"SwiftTerm_selectionBackgroundColor";
        case 4: return (__bridge const void *)@"CmdySelectionBackground";
        case 5: return (__bridge const void *)NSUnderlineColorAttributeName;
        case 6: return (__bridge const void *)@"CmdyUnderlineColor";
        case 7: return (__bridge const void *)NSStrikethroughColorAttributeName;
        case 8: return (__bridge const void *)NSLigatureAttributeName;
        case 9: return (__bridge const void *)NSUnderlineStyleAttributeName;
        case 10: return (__bridge const void *)@"SwiftTermUnderlineStyle";
        case 11: return (__bridge const void *)NSStrikethroughStyleAttributeName;
        case 12: return (__bridge const void *)NSKernAttributeName;
        default: return NULL;
    }
}
unsigned cmdy_platform_text_object_kind(const void *object) {
    id value = (__bridge id)object;
    if ([value isKindOfClass:NSFont.class]) return 1;
    if ([value isKindOfClass:NSColor.class]) return 2;
    if ([value isKindOfClass:NSNumber.class]) return 3;
    return 0;
}
long long cmdy_platform_text_number_integer(const void *object) { return [(__bridge NSNumber *)object longLongValue]; }
double cmdy_platform_text_number_double(const void *object) { return [(__bridge NSNumber *)object doubleValue]; }
const void *cmdy_platform_text_font_scaled(const void *font,double size) { return (__bridge_retained const void *)[NSFont fontWithDescriptor:[(__bridge NSFont *)font fontDescriptor] size:size]; }
double cmdy_platform_text_font_size(const void *font) { return [(__bridge NSFont *)font pointSize]; }
uint8_t cmdy_platform_text_font_emoji_family(const void *font) { return [[(__bridge NSFont *)font familyName] localizedCaseInsensitiveContainsString:@"emoji"]; }
const void *cmdy_platform_text_color_device_rgb(const void *color) { return (__bridge const void *)[(__bridge NSColor *)color colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace]; }
double cmdy_platform_text_color_component(const void *color,unsigned index) {
    NSColor *value = (__bridge NSColor *)color;
    switch (index) { case 0:return value.redComponent; case 1:return value.greenComponent; case 2:return value.blueComponent; case 3:return value.alphaComponent; default:return 0; }
}
CGColorRef cmdy_platform_text_color_cg(const void *color) { return [(__bridge NSColor *)color CGColor]; }
const void *cmdy_platform_text_white(void) { return (__bridge const void *)NSColor.whiteColor; }
const void *cmdy_platform_text_color_snapshot(const void *color) {
    NSColor *rgb = [(__bridge NSColor *)color colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
    if (!rgb) return NULL;
    return (__bridge_retained const void *)[NSColor colorWithDeviceRed:rgb.redComponent
        green:rgb.greenComponent blue:rgb.blueComponent alpha:rgb.alphaComponent];
}
uint8_t cmdy_platform_text_is_attributed_string(const void *object) {
    return [(__bridge id)object isKindOfClass:NSAttributedString.class];
}
