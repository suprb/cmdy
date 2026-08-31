#import <Cocoa/Cocoa.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <unistd.h>

#include "include/cef_app.h"
#include "include/cef_sandbox_mac.h"
#include "include/wrapper/cef_library_loader.h"

namespace {

class CmdyChromiumHelperApp final : public CefApp {
public:
    void OnBeforeCommandLineProcessing(
        const CefString& processType,
        CefRefPtr<CefCommandLine> commandLine
    ) override {
        commandLine->AppendSwitch("use-mock-keychain");
    }

    IMPLEMENT_REFCOUNTING(CmdyChromiumHelperApp);
};

const char* frameworkPathFromArguments(
    int argc, char* argv[], char* storage, size_t storageSize
) {
    constexpr const char* prefix = "--framework-dir-path=";
    constexpr size_t prefixLength = 21;
    for (int index = 0; index < argc; ++index) {
        if (std::strncmp(argv[index], prefix, prefixLength) == 0) {
            std::snprintf(
                storage, storageSize, "%s/Chromium Embedded Framework",
                argv[index] + prefixLength);
            return storage;
        }
    }
    return nullptr;
}

bool hasArgument(int argc, char* argv[], const char* expected) {
    for (int index = 0; index < argc; ++index) {
        if (std::strcmp(argv[index], expected) == 0) return true;
    }
    return false;
}

const char* fallbackFrameworkPath(char* storage, size_t storageSize) {
    uint32_t executablePathSize = 0;
    _NSGetExecutablePath(nullptr, &executablePathSize);
    auto* executablePath = static_cast<char*>(std::malloc(executablePathSize));
    if (executablePath == nullptr) {
        return nullptr;
    }
    _NSGetExecutablePath(executablePath, &executablePathSize);
    NSString* executableDirectory = [[NSString stringWithUTF8String:executablePath]
        stringByDeletingLastPathComponent];
    std::free(executablePath);

    // This fallback supports CEF's standard self-contained app layout. The
    // helper executable is nested at
    // Contents/Frameworks/<Helper>.app/Contents/MacOS, so three parent hops
    // reach the Frameworks directory that contains CEF.
    NSString* framework = [[executableDirectory
        stringByAppendingPathComponent:
            @"../../../Chromium Embedded Framework.framework/"
             "Chromium Embedded Framework"] stringByStandardizingPath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:framework]) {
        return nullptr;
    }
    strlcpy(storage, framework.UTF8String, storageSize);
    return storage;
}

}  // namespace

int main(int argc, char* argv[]) {
    @autoreleasepool {
        char frameworkStorage[PATH_MAX] = {};
        const char* framework = frameworkPathFromArguments(
            argc, argv, frameworkStorage, sizeof(frameworkStorage));
        if (framework == nullptr) {
            framework = fallbackFrameworkPath(
                frameworkStorage, sizeof(frameworkStorage));
        }
        if (framework == nullptr) {
            std::fprintf(stderr, "chromium helper: unable to load CEF\n");
            return 1;
        }

        // Follow CEF's required macOS helper sequence exactly: initialize its
        // native sandbox first, then use the scoped helper loader. The scoped
        // loader resolves the framework inside this helper's enclosing app and
        // preserves the sandbox extension that permits the sealed framework to
        // load. A generic dlopen/cef_load_library call after sandbox entry is
        // intentionally rejected by macOS for external runtime bundles.
        CefScopedSandboxContext sandbox;
        if (!sandbox.Initialize(argc, argv)) {
            std::fprintf(stderr,
                         "chromium helper: sandbox initialization failed\n");
            return 1;
        }
        CefScopedLibraryLoader libraryLoader;
        if (!libraryLoader.LoadInHelper()) {
            const char* detail = dlerror();
            std::fprintf(stderr, "chromium helper: unable to load CEF%s%s\n",
                         detail ? ": " : "", detail ? detail : "");
            return 1;
        }
        // Build/CI seam: prove that the production helper can load and enter
        // the pinned CEF sandbox without starting a long-lived renderer. The
        // flag is harmless in production (it only exits this helper process).
        if (hasArgument(argc, argv, "--cmdy-sandbox-smoke")) {
            std::fprintf(stderr, "chromium helper: sandbox smoke passed\n");
            return 0;
        }

        CefMainArgs mainArguments(argc, argv);
        CefRefPtr<CefApp> app = new CmdyChromiumHelperApp();
        return CefExecuteProcess(mainArguments, app.get(), nullptr);
    }
}
