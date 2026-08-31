#import <AppKit/AppKit.h>
#import <objc/runtime.h>

extern "C" int cef_bridge_init(const char* helperPath, const char* cachePath);

/// The original bridge was written for an executable living beside
/// Frameworks/. In hosted mode NSBundle.main is Cmdy, while CEF remains in
/// the optional Browser Extension. Temporarily answer the Extension's
/// Frameworks directory during CefInitialize so its copied CefSettings points
/// at the real payload. The AppKit method is restored before returning.
static IMP cmdyOriginalPrivateFrameworksPath = nullptr;
static NSString* cmdyHostedFrameworksPath = nil;

static NSString* cmdyPrivateFrameworksPath(
    NSBundle* bundle, SEL selector
) {
    if (bundle == NSBundle.mainBundle && cmdyHostedFrameworksPath != nil) {
        return cmdyHostedFrameworksPath;
    }
    if (cmdyOriginalPrivateFrameworksPath != nullptr) {
        using Getter = NSString* (*)(id, SEL);
        return reinterpret_cast<Getter>(
            cmdyOriginalPrivateFrameworksPath)(bundle, selector);
    }
    return nil;
}

extern "C" __attribute__((visibility("default")))
int cmdy_cef_bridge_init_with_framework(
    const char* helperPath,
    const char* cachePath,
    const char* frameworksPath
) {
    if (frameworksPath == nullptr) {
        return cef_bridge_init(helperPath, cachePath);
    }
    Method method = class_getInstanceMethod(
        NSBundle.class, @selector(privateFrameworksPath));
    if (method == nullptr) {
        return cef_bridge_init(helperPath, cachePath);
    }

    cmdyHostedFrameworksPath = [NSString stringWithUTF8String:frameworksPath];
    cmdyOriginalPrivateFrameworksPath = method_getImplementation(method);
    method_setImplementation(
        method, reinterpret_cast<IMP>(cmdyPrivateFrameworksPath));
    const int result = cef_bridge_init(helperPath, cachePath);
    method_setImplementation(method, cmdyOriginalPrivateFrameworksPath);
    cmdyOriginalPrivateFrameworksPath = nullptr;
    cmdyHostedFrameworksPath = nil;
    return result;
}
