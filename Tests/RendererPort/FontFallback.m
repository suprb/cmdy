// Headless raster and registration-order checks: no application, windows or PTY.
#import <AppKit/AppKit.h>
#import <CoreText/CoreText.h>
#include "cmdy_render_text.h"
#include <assert.h>
#include <pthread.h>
#include <stdio.h>

static NSArray<NSURL *> *fontURLs;
static unsigned loaderCalls;
static bool failFirst;

static void registerFont(NSURL *url) {
    CFErrorRef error = NULL;
    bool ok = CTFontManagerRegisterFontsForURL((__bridge CFURLRef)url, kCTFontManagerScopeProcess, &error);
    assert(ok || (error && CFErrorGetCode(error) == kCTFontManagerErrorAlreadyRegistered));
    if (error) CFRelease(error);
}

static uint8_t loadFallbacks(void) {
    @autoreleasepool {
        loaderCalls++;
        if (failFirst && loaderCalls == 1) return 0;
        for (NSURL *url in fontURLs) registerFont(url);
        return 1;
    }
}

static NSArray *rect(CmdyRenderRect value) {
    return @[@(value.x), @(value.y), @(value.width), @(value.height)];
}

static NSArray *color(CmdyRenderColor value) {
    return @[@(value.r), @(value.g), @(value.b), @(value.a)];
}

static NSArray *solids(const CmdyRenderSolid *values, size_t count) {
    NSMutableArray *result = [NSMutableArray new];
    for (size_t i = 0; i < count; i++) [result addObject:@[rect(values[i].rect), color(values[i].color)]];
    return result;
}

static NSDictionary *raster(NSString *text, NSFont *primary) {
    CmdyRenderRowRaster *row;
    __weak NSAttributedString *expired;
    @autoreleasepool {
        NSAttributedString *attributed = [[NSAttributedString alloc] initWithString:text attributes:@{
            NSFontAttributeName:primary, NSForegroundColorAttributeName:NSColor.whiteColor,
            NSUnderlineStyleAttributeName:@1}];
        expired = attributed;
        __block NSInteger characters = 0;
        [text enumerateSubstringsInRange:NSMakeRange(0, text.length)
            options:NSStringEnumerationByComposedCharacterSequences
            usingBlock:^(NSString *substring, NSRange range, NSRange enclosing, BOOL *stop) {
                (void)substring; (void)range; (void)enclosing; (void)stop; characters++;
            }];
        CmdyRenderTextSegment segment = {.attributed_string=(__bridge const void *)attributed,
            .column_width=2, .character_count=characters};
        CmdyRenderRowInput input = {.segments=&segment, .segment_count=1,
            .cols=128, .width=2048, .height=40, .cell_width=16, .cell_height=40, .scale=2,
            .underline_position=4, .underline_thickness=2, .normal_font=(__bridge const void *)primary,
            .foreground=(__bridge const void *)NSColor.whiteColor, .coverage_exponent=1.35,
            .snaps_y=1, .ascii_caching=1, .font_caching=1};
        row = cmdy_render_row_create(&input); assert(row);
    }
    assert(expired == nil); // Native raster owns the glyph fonts after inputs die.
    CmdyRenderRowView view = {0}; cmdy_render_row_view(row, &view);
    assert(view.coverage_count > 0);
    bool visible = view.color_tile_count > 0;
    for (size_t i = 0; i < view.coverage_count && !visible; i++) visible = view.coverage[i] != 0;
    assert(visible);
    NSMutableArray *glyphs = [NSMutableArray new], *tints = [NSMutableArray new], *tiles = [NSMutableArray new];
    for (size_t i = 0; i < view.glyph_count; i++) {
        const CmdyRenderGlyphSeed *glyph = &view.glyphs[i];
        NSString *name = CFBridgingRelease(CTFontCopyPostScriptName(glyph->font)); assert(name);
        [glyphs addObject:@[name, @(glyph->glyph), rect(glyph->rect), color(glyph->color)]];
    }
    for (size_t i = 0; i < view.tint_count; i++) {
        const CmdyRenderTint *tint = &view.tints[i];
        [tints addObject:@[rect(tint->rect), rect(tint->envelope), color(tint->color),
            @(tint->has_envelope), @(tint->replaced_by_atlas)]];
    }
    for (size_t i = 0; i < view.color_tile_count; i++) {
        const CmdyRenderColorTile *tile = &view.color_tiles[i];
        [tiles addObject:@[rect(tile->rect), @(tile->width), @(tile->height),
            [[NSData dataWithBytes:tile->bytes length:tile->byte_count] base64EncodedStringWithOptions:0]]];
    }
    NSDictionary *result = @{@"text":text, @"size":@[@(view.width), @(view.height)],
        @"coverage":[[NSData dataWithBytes:view.coverage length:view.coverage_count] base64EncodedStringWithOptions:0],
        @"glyphs":glyphs, @"tints":tints, @"tiles":tiles,
        @"backgrounds":solids(view.backgrounds, view.background_count),
        @"decorations":solids(view.decorations, view.decoration_count)};
    cmdy_render_row_free(row);
    return result;
}

static dispatch_semaphore_t startWorkers;
typedef struct Work { void *font; void *result; } Work;
static void *renderConcurrent(void *raw) {
    @autoreleasepool {
        Work *work = raw;
        NSFont *font = (__bridge NSFont *)work->font;
        dispatch_semaphore_wait(startWorkers, DISPATCH_TIME_FOREVER);
        NSDictionary *reference = raster(@"A中😀\U0010FFFF", font);
        for (int i = 1; i < 32; i++) {
            @autoreleasepool { assert([reference isEqual:raster(@"A中😀\U0010FFFF", font)]); }
        }
        work->result = (__bridge_retained void *)reference;
    }
    return NULL;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        assert(argc == 4);
        NSString *mode = [NSString stringWithUTF8String:argv[1]];
        NSURL *root = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]] isDirectory:YES];
        NSArray<NSURL *> *contents = [NSFileManager.defaultManager contentsOfDirectoryAtURL:root includingPropertiesForKeys:nil options:0 error:NULL];
        NSMutableArray *urls = [NSMutableArray new];
        for (NSString *extension in @[@"ttf", @"otf"]) {
            for (NSURL *url in contents) if ([url.pathExtension isEqualToString:extension]) [urls addObject:url];
        }
        fontURLs = urls; assert(fontURLs.count == 35);
        NSData *data = [NSData dataWithContentsOfURL:[root URLByAppendingPathComponent:@"catalog.json"]]; assert(data);
        NSArray<NSDictionary *> *catalog = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        NSString *name = [NSString stringWithUTF8String:argv[3]];
        bool eager = [mode isEqualToString:@"eager"];
        if (eager) for (NSURL *url in fontURLs) registerFont(url);
        else {
            for (NSDictionary *entry in catalog) if ([entry[@"fontName"] isEqualToString:name])
                registerFont([root URLByAppendingPathComponent:entry[@"resource"]]);
        }
        NSFont *primary = [NSFont fontWithName:name size:14]; assert(primary);
#ifndef CMDY_LEGACY_FONTS
        if (!eager) {
            assert(cmdy_render_set_font_fallback_loader(NULL) == 0);
            assert(cmdy_render_set_font_fallback_loader(loadFallbacks) == 1);
            assert(cmdy_render_set_font_fallback_loader(loadFallbacks) == 0);
        }
#else
        assert(eager);
        (void)loadFallbacks;
#endif
        NSMutableArray *records = [NSMutableArray new];
        [records addObject:raster(@"ASCII -> <= !=", primary)];
        assert(loaderCalls == 0);
        failFirst = [mode isEqualToString:@"retry"];
        if (failFirst) {
            (void)raster(@"\U0010FFFF", primary); assert(loaderCalls == 1);
            (void)raster(@"\U0010FFFF", primary); assert(loaderCalls == 2);
        }
        if ([mode isEqualToString:@"concurrent"]) {
            pthread_t threads[8]; Work work[8] = {0};
            startWorkers = dispatch_semaphore_create(0);
            for (int i = 0; i < 8; i++) {
                work[i].font = (__bridge void *)primary;
                assert(pthread_create(&threads[i], NULL, renderConcurrent, &work[i]) == 0);
            }
            for (int i = 0; i < 8; i++) dispatch_semaphore_signal(startWorkers);
            NSDictionary *reference = nil;
            for (int i = 0; i < 8; i++) {
                assert(pthread_join(threads[i], NULL) == 0);
                NSDictionary *result = CFBridgingRelease(work[i].result);
                if (reference) assert([reference isEqual:result]); else reference = result;
            }
            assert(loaderCalls == 1);
        }
        NSArray *texts = @[@"café Å ö", @"e\u0301 A\u030A", @"Ελληνικά", @"Привет",
            @"中文 日本語 한글", @"العربية", @"हिन्दी", @"ไทย", @"∑ ∫ √ ∞ ℵ ⊗",
            @"\uE0B0 \uE0B2 \uF015 \uF120", @"😀 🌍", @"👨‍👩‍👧‍👦", @"🇸🇪 🇺🇸", @"❤️ ✈️", @"𝔄 𝕏 𝟘", @"A中😀\U0010FFFF"];
        for (NSString *text in texts) [records addObject:raster(text, primary)];
        assert(loaderCalls == (eager ? 0u : failFirst ? 2u : 1u));
        NSDictionary *output = @{@"cases":records, @"loaderCalls":@(loaderCalls),
            @"workerRenders":@([mode isEqualToString:@"concurrent"] ? 256 : 0)};
        NSData *json = [NSJSONSerialization dataWithJSONObject:output options:NSJSONWritingSortedKeys error:NULL]; assert(json);
        assert(fwrite(json.bytes, 1, json.length, stdout) == json.length); puts("");
    }
    return 0;
}
