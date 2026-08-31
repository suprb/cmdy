// Copyright (c) 2026 Andreas Pihlstrom
// SPDX-License-Identifier: MIT
//
// Objective-C++ bridge between the CEF C++ API and Swift.
// Uses libcef_dll_wrapper for the C++ API.
// Supports multiple browser instances keyed by integer handle.

#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#include <crt_externs.h>  // _NSGetArgc, _NSGetArgv
#include <dlfcn.h>
#include <mach-o/dyld.h>  // _NSGetExecutablePath
#include <chrono>
#include <cstring>
#include <map>
#include <set>
#include <string>
#include <thread>
#import "include/cef_bridge.h"
#include "bridge_lifecycle.h"

// CEF C++ headers
#include "include/cef_app.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_life_span_handler.h"
#include "include/cef_display_handler.h"
#include "include/cef_load_handler.h"
#include "include/cef_request_handler.h"
#include "include/wrapper/cef_helpers.h"
#include "include/wrapper/cef_library_loader.h"

// ============================================================================
// Per-browser callback state
// ============================================================================

struct BrowserCallbacks {
    CEFBrowserViewCreatedCallback viewCb = nullptr;
    CEFPageLoadedCallback pageCb = nullptr;
    CEFConsoleMessageCallback consoleCb = nullptr;
    CEFBrowserClosedCallback closedCb = nullptr;
    void* context = nullptr;
};

// ============================================================================
// Global state
// ============================================================================

// Map: our handle (intptr_t) → CefRefPtr<CefBrowser>
static std::map<intptr_t, CefRefPtr<CefBrowser>> g_browsers;
// Map: CEF browser ID → our handle
static std::map<int, intptr_t> g_cef_to_handle;
// Map: our handle → callbacks
static std::map<intptr_t, BrowserCallbacks> g_callbacks;
// Keep each per-browser client alive from asynchronous CreateBrowser through
// OnBeforeClose. Its lifespan handler carries the stable create identity.
static std::map<intptr_t, CefRefPtr<CefClient>> g_clients;
static cmdy::cef_bridge::BrowserLifecycleRegistry g_lifecycle;
// DevTools is a second CEF browser. It must never reuse the primary client's
// lifecycle handler or overwrite the primary handle's bridge state.
static std::set<intptr_t> g_devtools_requested_handles;
static cmdy::cef_bridge::AuxiliaryBrowserLifecycle g_devtools_lifecycle;

static bool g_initialized = false;

struct SandboxRuntime {
    using Initialize = void* (*)(int, char**);
    using Destroy = void (*)(void*);

    void* library = nullptr;
    void* context = nullptr;
    Destroy destroy = nullptr;
};

static SandboxRuntime g_subprocess_sandbox;

static bool isSubprocessInvocation() {
    const int argc = *_NSGetArgc();
    char** argv = *_NSGetArgv();
    for (int index = 0; index < argc; ++index) {
        if (strncmp(argv[index], "--type=", 7) == 0) return true;
    }
    return false;
}

static SandboxRuntime loadSandbox(
    const char* frameworkPath, int argc, char** argv
) {
    SandboxRuntime runtime;
    if (!frameworkPath) return runtime;

    NSString* frameworkBinary = [NSString stringWithUTF8String:frameworkPath];
    NSString* sandboxPath = [[[frameworkBinary stringByDeletingLastPathComponent]
        stringByAppendingPathComponent:@"Libraries"]
        stringByAppendingPathComponent:@"libcef_sandbox.dylib"];
    runtime.library = dlopen(sandboxPath.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!runtime.library) {
        fprintf(stderr, "[CEFBridge] Unable to load sandbox: %s\n", dlerror());
        return runtime;
    }
    auto initialize = reinterpret_cast<SandboxRuntime::Initialize>(
        dlsym(runtime.library, "cef_sandbox_initialize"));
    runtime.destroy = reinterpret_cast<SandboxRuntime::Destroy>(
        dlsym(runtime.library, "cef_sandbox_destroy"));
    if (!initialize || !runtime.destroy) {
        fprintf(stderr, "[CEFBridge] Sandbox entry points are unavailable\n");
        dlclose(runtime.library);
        return {};
    }
    runtime.context = initialize(argc, argv);
    if (!runtime.context) {
        fprintf(stderr, "[CEFBridge] Sandbox initialization failed\n");
        dlclose(runtime.library);
        return {};
    }
    return runtime;
}

static void destroySandbox(SandboxRuntime& runtime) {
    if (runtime.context && runtime.destroy) runtime.destroy(runtime.context);
    if (runtime.library) dlclose(runtime.library);
    runtime = {};
}

// ============================================================================
// Helper: look up CefBrowser by our handle
// ============================================================================

static CefRefPtr<CefBrowser> getBrowser(CEFBrowserHandle handle) {
    intptr_t h = (intptr_t)handle;
    auto it = g_browsers.find(h);
    if (it != g_browsers.end()) return it->second;
    return nullptr;
}

static intptr_t handleForCefId(int cefId) {
    auto it = g_cef_to_handle.find(cefId);
    if (it != g_cef_to_handle.end()) return it->second;
    return 0;
}

// ============================================================================
// ChromiumClient — handles browser lifecycle and display events
// ============================================================================

class ChromiumLifeSpanHandler : public CefLifeSpanHandler {
public:
    explicit ChromiumLifeSpanHandler(intptr_t handle) : handle_(handle) {}

    void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
        CEF_REQUIRE_UI_THREAD();
        const int cefId = browser->GetIdentifier();
        const auto action = g_lifecycle.didCreate(handle_);
        if (action == cmdy::cef_bridge::BrowserCreatedAction::unknownHandle) {
            fprintf(stderr,
                    "[CEFBridge] OnAfterCreated: unknown handle %ld for CEF ID %d; closing\n",
                    (long)handle_, cefId);
            browser->GetHost()->CloseBrowser(true);
            return;
        }

        g_browsers[handle_] = browser;
        g_cef_to_handle[cefId] = handle_;
        fprintf(stderr, "[CEFBridge] Browser created (CEF ID=%d, handle=%ld)\n",
                cefId, (long)handle_);

        if (action == cmdy::cef_bridge::BrowserCreatedAction::closeImmediately) {
            fprintf(stderr, "[CEFBridge] Applying pending close for handle %ld\n",
                    (long)handle_);
            browser->GetHost()->CloseBrowser(true);
            return;
        }

        // Notify Swift with the browser view
        CefWindowHandle nsView = browser->GetHost()->GetWindowHandle();
        auto cbIt = g_callbacks.find(handle_);
        if (nsView && cbIt != g_callbacks.end() && cbIt->second.viewCb) {
            cbIt->second.viewCb(
                (CEFBrowserHandle)handle_, nsView, cbIt->second.context);
            fprintf(stderr, "[CEFBridge] View created callback invoked for handle %ld\n",
                    (long)handle_);
        }
    }

    bool DoClose(CefRefPtr<CefBrowser> browser) override {
        CEF_REQUIRE_UI_THREAD();
        return false;  // Allow the close
    }

    void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
        CEF_REQUIRE_UI_THREAD();
        const int cefId = browser->GetIdentifier();
        BrowserCallbacks callbacks;
        const auto callbackIterator = g_callbacks.find(handle_);
        if (callbackIterator != g_callbacks.end()) {
            callbacks = callbackIterator->second;
        }

        g_browsers.erase(handle_);
        g_cef_to_handle.erase(cefId);
        g_callbacks.erase(handle_);
        g_clients.erase(handle_);
        g_lifecycle.didClose(handle_);
        fprintf(stderr, "[CEFBridge] Browser closed (handle=%ld)\n", (long)handle_);

        // Invoke this after all bridge state is gone. The callback may release
        // the final owner of its context and re-enter host-side bookkeeping.
        if (callbacks.closedCb) {
            callbacks.closedCb((CEFBrowserHandle)handle_, callbacks.context);
        }
    }

    IMPLEMENT_REFCOUNTING(ChromiumLifeSpanHandler);

private:
    const intptr_t handle_;
};

class ChromiumDisplayHandler : public CefDisplayHandler {
public:
    bool OnConsoleMessage(CefRefPtr<CefBrowser> browser,
                          cef_log_severity_t level,
                          const CefString& message,
                          const CefString& source,
                          int line) override {
        intptr_t handle = handleForCefId(browser->GetIdentifier());
        auto cbIt = g_callbacks.find(handle);
        if (handle && cbIt != g_callbacks.end() && cbIt->second.consoleCb) {
            std::string msg = message.ToString();
            std::string src = source.ToString();
            cbIt->second.consoleCb((CEFBrowserHandle)handle, msg.c_str(), src.c_str(), line, cbIt->second.context);
        }
        return false;
    }

    IMPLEMENT_REFCOUNTING(ChromiumDisplayHandler);
};

class ChromiumLoadHandler : public CefLoadHandler {
public:
    void OnLoadStart(CefRefPtr<CefBrowser> browser,
                     CefRefPtr<CefFrame> frame,
                     TransitionType transition_type) override {
        std::string url = frame->GetURL().ToString();
        intptr_t handle = handleForCefId(browser->GetIdentifier());
        fprintf(stderr, "[CEFBridge] OnLoadStart: handle=%ld isMain=%d url=%s\n",
                (long)handle, frame->IsMain(), url.c_str());
    }

    void OnLoadEnd(CefRefPtr<CefBrowser> browser,
                   CefRefPtr<CefFrame> frame,
                   int httpStatusCode) override {
        intptr_t handle = handleForCefId(browser->GetIdentifier());
        if (frame->IsMain() && handle) {
            auto cbIt = g_callbacks.find(handle);
            if (cbIt != g_callbacks.end() && cbIt->second.pageCb) {
                std::string url = frame->GetURL().ToString();
                cbIt->second.pageCb((CEFBrowserHandle)handle, url.c_str(), cbIt->second.context);
            }
        }
    }

    void OnLoadError(CefRefPtr<CefBrowser> browser,
                     CefRefPtr<CefFrame> frame,
                     ErrorCode errorCode,
                     const CefString& errorText,
                     const CefString& failedUrl) override {
        std::string errStr = errorText.ToString();
        std::string failUrl = failedUrl.ToString();
        intptr_t handle = handleForCefId(browser->GetIdentifier());
        fprintf(stderr, "[CEFBridge] OnLoadError: handle=%ld error=%d text=%s url=%s\n",
                (long)handle, errorCode, errStr.c_str(), failUrl.c_str());
    }

    void OnLoadingStateChange(CefRefPtr<CefBrowser> browser,
                              bool isLoading,
                              bool canGoBack,
                              bool canGoForward) override {
        // Intentionally quiet — only log errors
    }

    IMPLEMENT_REFCOUNTING(ChromiumLoadHandler);
};

class ChromiumRequestHandler : public CefRequestHandler {
public:
    void OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser,
                                    TerminationStatus status,
                                    int error_code,
                                    const CefString& error_string) override {
        const char* statusStr = "unknown";
        switch (status) {
            case TS_ABNORMAL_TERMINATION: statusStr = "ABNORMAL"; break;
            case TS_PROCESS_WAS_KILLED: statusStr = "KILLED"; break;
            case TS_PROCESS_CRASHED: statusStr = "CRASHED"; break;
            case TS_PROCESS_OOM: statusStr = "OOM"; break;
            case 4: statusStr = "LAUNCH_FAILED"; break;
            case 5: statusStr = "INTEGRITY_FAILURE"; break;
            default: break;
        }
        intptr_t handle = handleForCefId(browser->GetIdentifier());
        fprintf(stderr, "[CEFBridge] OnRenderProcessTerminated: handle=%ld status=%s(%d) error=%d msg=%s\n",
                (long)handle, statusStr, status,
                error_code, error_string.ToString().c_str());
    }

    IMPLEMENT_REFCOUNTING(ChromiumRequestHandler);
};

class ChromiumClient : public CefClient {
public:
    explicit ChromiumClient(intptr_t handle)
        : life_span_handler_(new ChromiumLifeSpanHandler(handle)),
          display_handler_(new ChromiumDisplayHandler()),
          load_handler_(new ChromiumLoadHandler()),
          request_handler_(new ChromiumRequestHandler()) {}

    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override {
        return life_span_handler_;
    }

    CefRefPtr<CefDisplayHandler> GetDisplayHandler() override {
        return display_handler_;
    }

    CefRefPtr<CefLoadHandler> GetLoadHandler() override {
        return load_handler_;
    }

    CefRefPtr<CefRequestHandler> GetRequestHandler() override {
        return request_handler_;
    }

    IMPLEMENT_REFCOUNTING(ChromiumClient);

private:
    CefRefPtr<ChromiumLifeSpanHandler> life_span_handler_;
    CefRefPtr<ChromiumDisplayHandler> display_handler_;
    CefRefPtr<ChromiumLoadHandler> load_handler_;
    CefRefPtr<ChromiumRequestHandler> request_handler_;
};

class ChromiumDevToolsLifeSpanHandler : public CefLifeSpanHandler {
public:
    void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
        CEF_REQUIRE_UI_THREAD();
        g_devtools_lifecycle.didCreate(browser->GetIdentifier());
    }

    bool DoClose(CefRefPtr<CefBrowser> browser) override {
        CEF_REQUIRE_UI_THREAD();
        return false;
    }

    void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
        CEF_REQUIRE_UI_THREAD();
        g_devtools_lifecycle.didClose(browser->GetIdentifier());
        const auto opener = g_cef_to_handle.find(browser->GetHost()->GetOpenerIdentifier());
        if (opener != g_cef_to_handle.end()) {
            g_devtools_requested_handles.erase(opener->second);
        }
    }

    IMPLEMENT_REFCOUNTING(ChromiumDevToolsLifeSpanHandler);
};

class ChromiumDevToolsClient : public CefClient {
public:
    ChromiumDevToolsClient()
        : life_span_handler_(new ChromiumDevToolsLifeSpanHandler()) {}

    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override {
        return life_span_handler_;
    }

    IMPLEMENT_REFCOUNTING(ChromiumDevToolsClient);

private:
    CefRefPtr<ChromiumDevToolsLifeSpanHandler> life_span_handler_;
};

static CefRefPtr<ChromiumDevToolsClient> g_devtools_client;

// ============================================================================
// ChromiumApp — application-level callbacks
// ============================================================================

class ChromiumApp : public CefApp, public CefBrowserProcessHandler {
public:
    CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override {
        return this;
    }

    void OnBeforeCommandLineProcessing(
        const CefString& process_type,
        CefRefPtr<CefCommandLine> command_line) override {
        // Prevent "Chromium Safe Storage" keychain prompt
        command_line->AppendSwitch("use-mock-keychain");
    }

    void OnContextInitialized() override {
        CEF_REQUIRE_UI_THREAD();
        fprintf(stderr, "[CEFBridge] CEF context initialized\n");
    }

    IMPLEMENT_REFCOUNTING(ChromiumApp);
};

static CefRefPtr<ChromiumApp> g_app;

// ============================================================================
// NSApplication CefAppProtocol support via runtime injection
// ============================================================================

static BOOL g_handlingSendEvent = NO;
static IMP g_originalSendEvent = NULL;

static BOOL cef_isHandlingSendEvent(id self, SEL _cmd) {
    return g_handlingSendEvent;
}

static void cef_setHandlingSendEvent(id self, SEL _cmd, BOOL handling) {
    g_handlingSendEvent = handling;
}

static void cef_swizzledSendEvent(id self, SEL _cmd, NSEvent* event) {
    BOOL wasHandling = g_handlingSendEvent;
    g_handlingSendEvent = YES;
    // Call original sendEvent:
    ((void (*)(id, SEL, NSEvent*))g_originalSendEvent)(self, _cmd, event);
    g_handlingSendEvent = wasHandling;
}

static void installCefAppProtocol(void) {
    Class appClass = [NSApplication class];

    // Add isHandlingSendEvent
    class_addMethod(appClass,
                    @selector(isHandlingSendEvent),
                    (IMP)cef_isHandlingSendEvent,
                    "c@:");

    // Add setHandlingSendEvent:
    class_addMethod(appClass,
                    @selector(setHandlingSendEvent:),
                    (IMP)cef_setHandlingSendEvent,
                    "v@:c");

    // Swizzle sendEvent: to wrap with handling flag
    Method original = class_getInstanceMethod(appClass, @selector(sendEvent:));
    if (original) {
        g_originalSendEvent = method_getImplementation(original);
        method_setImplementation(original, (IMP)cef_swizzledSendEvent);
    }

    fprintf(stderr, "[CEFBridge] CefAppProtocol installed on NSApplication\n");
}

// ============================================================================
// Public C API
// ============================================================================

int cef_bridge_load_library(const char* frameworkPath) {
    fprintf(stderr, "[CEFBridge] Loading library from: %s\n", frameworkPath);

    // The helper process must enter CEF's macOS sandbox before loading the
    // main framework. External payloads cannot use CEF's relative-path helper,
    // so resolve the pinned sandbox dylib beside the supplied framework.
    if (isSubprocessInvocation()) {
        g_subprocess_sandbox = loadSandbox(
            frameworkPath, *_NSGetArgc(), *_NSGetArgv());
        if (!g_subprocess_sandbox.context) {
            fprintf(stderr,
                    "[CEFBridge] Refusing to load subprocess without sandbox\n");
            return 0;
        }
    }

    if (!cef_load_library(frameworkPath)) {
        fprintf(stderr, "[CEFBridge] cef_load_library failed\n");
        destroySandbox(g_subprocess_sandbox);
        return 0;
    }

    fprintf(stderr, "[CEFBridge] Library loaded successfully\n");
    return 1;
}

int cef_bridge_init(const char* helperPath, const char* cachePath) {
    if (g_initialized) {
        fprintf(stderr, "[CEFBridge] Already initialized\n");
        return 1;
    }

    CefMainArgs main_args(*_NSGetArgc(), *_NSGetArgv());

    CefSettings settings;
    // Fail closed: CEF's macOS sandbox and process-signature validation stay
    // enabled. There is intentionally no no-sandbox fallback.
    settings.no_sandbox = false;
    settings.external_message_pump = true;
    settings.multi_threaded_message_loop = false;
    settings.log_severity = LOGSEVERITY_WARNING;
    settings.command_line_args_disabled = false;

    if (helperPath) {
        CefString(&settings.browser_subprocess_path).FromASCII(helperPath);
    } else {
        // Check for Helper.app inside the bundle (dist builds)
        NSString* helperApp = [[[NSBundle mainBundle] privateFrameworksPath]
            stringByAppendingPathComponent:@"Chromium Helper.app/Contents/MacOS/Chromium Helper"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:helperApp]) {
            CefString(&settings.browser_subprocess_path).FromString([helperApp UTF8String]);
            fprintf(stderr, "[CEFBridge] Using Helper.app: %s\n", [helperApp UTF8String]);
        } else {
            // Development: use the main executable as the subprocess helper
            uint32_t bufsize = 0;
            _NSGetExecutablePath(NULL, &bufsize);
            char* execPath = (char*)malloc(bufsize);
            _NSGetExecutablePath(execPath, &bufsize);
            CefString(&settings.browser_subprocess_path).FromASCII(execPath);
            fprintf(stderr, "[CEFBridge] Using main executable as subprocess: %s\n", execPath);
            free(execPath);
        }
    }

    if (cachePath) {
        CefString(&settings.root_cache_path).FromASCII(cachePath);
    } else {
        // Use a temp directory for cache
        NSString* cache = [NSTemporaryDirectory() stringByAppendingPathComponent:@"cmdy-cef-cache"];
        CefString(&settings.root_cache_path).FromString([cache UTF8String]);
    }

    // Set the framework directory path so CEF can find its resources
    NSString* fwPath = nil;
    NSString* bundleFw = [[[NSBundle mainBundle] privateFrameworksPath]
        stringByAppendingPathComponent:@"Chromium Embedded Framework.framework"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:bundleFw]) {
        fwPath = bundleFw;
    } else {
        // Development fallback: look relative to executable
        uint32_t bufsize = 0;
        _NSGetExecutablePath(NULL, &bufsize);
        char* execPath = (char*)malloc(bufsize);
        _NSGetExecutablePath(execPath, &bufsize);
        NSString* execDir = [[NSString stringWithUTF8String:execPath] stringByDeletingLastPathComponent];
        free(execPath);
        fwPath = [[execDir stringByAppendingPathComponent:@"../../../Frameworks/Chromium Embedded Framework.framework"]
            stringByStandardizingPath];
    }
    if (fwPath) {
        CefString(&settings.framework_dir_path).FromString([fwPath UTF8String]);
        fprintf(stderr, "[CEFBridge] Framework dir: %s\n", [fwPath UTF8String]);

        // A separately downloaded Browser runtime is still a complete macOS
        // app bundle. Tell CEF which bundle owns the helper and framework so
        // its native sandbox grants access to that sealed bundle instead of
        // assuming NSBundle.main (cmdy.app). This is CEF's supported external
        // bundle hook; it does not relax or disable the sandbox.
        NSString* runtimeBundle = [[[[fwPath stringByDeletingLastPathComponent]
            stringByDeletingLastPathComponent]
            stringByDeletingLastPathComponent] stringByStandardizingPath];
        if ([runtimeBundle.pathExtension caseInsensitiveCompare:@"app"]
                == NSOrderedSame) {
            CefString(&settings.main_bundle_path).FromString(
                runtimeBundle.UTF8String);
            fprintf(stderr, "[CEFBridge] Main bundle: %s\n",
                    runtimeBundle.UTF8String);
        }
    }

    // Install CefAppProtocol on NSApplication before initializing CEF
    installCefAppProtocol();

    g_app = new ChromiumApp();

    // CefExecuteProcess must be called first for sub-process args detection
    int exit_code = CefExecuteProcess(main_args, g_app.get(), nullptr);
    if (exit_code >= 0) {
        _exit(exit_code);
    }

    fprintf(stderr, "[CEFBridge] Browser process PID=%d\n", getpid());

    if (!CefInitialize(main_args, settings, g_app.get(), nullptr)) {
        fprintf(stderr, "[CEFBridge] CefInitialize failed\n");
        return 0;
    }

    g_initialized = true;
    fprintf(stderr, "[CEFBridge] CEF initialized successfully\n");
    return 1;
}

void cef_bridge_do_message_loop_work(void) {
    if (g_initialized) {
        CefDoMessageLoopWork();
    }
}

CEFBrowserHandle cef_bridge_create_browser(void* parentView, const char* url,
                                            CEFBrowserViewCreatedCallback viewCb,
                                            CEFPageLoadedCallback pageCb,
                                            CEFConsoleMessageCallback consoleCb,
                                            void* context) {
    return cef_bridge_create_browser_v2(
        parentView, url, viewCb, pageCb, consoleCb, nullptr, context);
}

CEFBrowserHandle cef_bridge_create_browser_v2(
    void* parentView, const char* url,
    CEFBrowserViewCreatedCallback viewCb,
    CEFPageLoadedCallback pageCb,
    CEFConsoleMessageCallback consoleCb,
    CEFBrowserClosedCallback closedCb,
    void* context
) {
    if (!g_initialized) {
        fprintf(stderr, "[CEFBridge] Cannot create browser — not initialized\n");
        return nullptr;
    }

    const intptr_t handle = g_lifecycle.reserve();

    // Store callbacks
    BrowserCallbacks cbs;
    cbs.viewCb = viewCb;
    cbs.pageCb = pageCb;
    cbs.consoleCb = consoleCb;
    cbs.closedCb = closedCb;
    cbs.context = context;
    g_callbacks[handle] = cbs;

    // Every asynchronous create gets its own client/lifespan handler carrying
    // this handle. Callback order can no longer overwrite global identity.
    CefRefPtr<ChromiumClient> client = new ChromiumClient(handle);
    g_clients[handle] = client;

    CefWindowInfo window_info;

    if (parentView) {
        NSView* parent = (__bridge NSView*)parentView;
        NSRect frame = parent.bounds;
        CefRect cef_rect(0, 0, (int)frame.size.width, (int)frame.size.height);
        window_info.SetAsChild(parentView, cef_rect);
    }

    CefBrowserSettings browser_settings;

    CefString cef_url;
    if (url) {
        cef_url.FromASCII(url);
    } else {
        cef_url.FromASCII("about:blank");
    }

    fprintf(stderr, "[CEFBridge] Creating browser (handle=%ld, url=%s, parent=%p)...\n",
            (long)handle, url ?: "about:blank", parentView);

    bool result = CefBrowserHost::CreateBrowser(
        window_info,
        client,
        cef_url,
        browser_settings,
        nullptr,  // extra_info
        nullptr   // request_context
    );

    if (!result) {
        fprintf(stderr, "[CEFBridge] CreateBrowser failed\n");
        g_callbacks.erase(handle);
        g_clients.erase(handle);
        g_lifecycle.cancelCreation(handle);
        return nullptr;
    }

    fprintf(stderr, "[CEFBridge] Browser creation initiated (handle=%ld)\n", (long)handle);
    return (CEFBrowserHandle)handle;
}

void cef_bridge_navigate(CEFBrowserHandle browser, const char* url) {
    auto b = getBrowser(browser);
    if (b && url) {
        CefString cef_url;
        cef_url.FromASCII(url);
        b->GetMainFrame()->LoadURL(cef_url);
    }
}

void cef_bridge_reload(CEFBrowserHandle browser) {
    auto b = getBrowser(browser);
    if (b) b->Reload();
}

void cef_bridge_go_back(CEFBrowserHandle browser) {
    auto b = getBrowser(browser);
    if (b) b->GoBack();
}

void cef_bridge_go_forward(CEFBrowserHandle browser) {
    auto b = getBrowser(browser);
    if (b) b->GoForward();
}

void cef_bridge_execute_js(CEFBrowserHandle browser, const char* code) {
    auto b = getBrowser(browser);
    if (b && code) {
        CefString cef_code;
        cef_code.FromASCII(code);
        b->GetMainFrame()->ExecuteJavaScript(cef_code, "", 0);
    }
}

char* cef_bridge_get_url(CEFBrowserHandle browser) {
    auto b = getBrowser(browser);
    if (b) {
        std::string url = b->GetMainFrame()->GetURL().ToString();
        return strdup(url.c_str());
    }
    return strdup("about:blank");
}

char* cef_bridge_get_title(CEFBrowserHandle browser) {
    // Title is not directly available synchronously — would need DisplayHandler
    return strdup("");
}

void cef_bridge_close_browser(CEFBrowserHandle browser) {
    const intptr_t handle = (intptr_t)browser;
    const auto action = g_lifecycle.requestClose(handle);
    if (action == cmdy::cef_bridge::BrowserCloseAction::closeBrowser) {
        auto b = getBrowser(browser);
        if (!b) {
            fprintf(stderr,
                    "[CEFBridge] Live handle %ld has no browser; awaiting shutdown guard\n",
                    (long)handle);
            return;
        }
        b->GetHost()->CloseDevTools();
        b->GetHost()->CloseBrowser(true);
    } else if (action == cmdy::cef_bridge::BrowserCloseAction::waitForCreation) {
        fprintf(stderr, "[CEFBridge] Close queued for creating handle %ld\n",
                (long)handle);
    }
}

int cef_bridge_subprocess_exec(void) {
    CefMainArgs main_args(*_NSGetArgc(), *_NSGetArgv());
    if (!g_subprocess_sandbox.context) {
        fprintf(stderr, "[CEFBridge] Refusing subprocess without macOS sandbox\n");
        return 1;
    }
    // Minimal app with just use-mock-keychain
    CefRefPtr<CefApp> app = new ChromiumApp();
    fprintf(stderr, "[CEFBridge] Subprocess exec (lightweight)...\n");
    fflush(stderr);
    int exit_code = CefExecuteProcess(main_args, app.get(), nullptr);
    destroySandbox(g_subprocess_sandbox);
    fprintf(stderr, "[CEFBridge] Subprocess exec returned: %d\n", exit_code);
    fflush(stderr);
    return exit_code;
}

void cef_bridge_shutdown(void) {
    if (!cef_bridge_shutdown_and_wait(10000)) {
        fprintf(stderr,
                "[CEFBridge] Shutdown timed out; leaving CEF loaded for process exit\n");
    }
}

int cef_bridge_browser_count(void) {
    return (int)g_lifecycle.size();
}

int cef_bridge_shutdown_and_wait(int timeoutMilliseconds) {
    if (!g_initialized) return 1;
    if (timeoutMilliseconds < 0) timeoutMilliseconds = 0;

    fprintf(stderr, "[CEFBridge] Closing %zu browser lifecycle(s)...\n",
            g_lifecycle.size());
    for (const auto handle : g_lifecycle.handles()) {
        cef_bridge_close_browser((CEFBrowserHandle)handle);
    }

    const auto deadline = std::chrono::steady_clock::now() +
        std::chrono::milliseconds(timeoutMilliseconds);
    while ((!g_lifecycle.empty() || !g_devtools_lifecycle.empty()) &&
           std::chrono::steady_clock::now() < deadline) {
        CefDoMessageLoopWork();
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }

    if (!g_lifecycle.empty() || !g_devtools_lifecycle.empty()) {
        fprintf(stderr,
                "[CEFBridge] Refusing CefShutdown with %zu primary, %zu DevTools, "
                "and %zu pending DevTools lifecycle(s) open\n",
                g_lifecycle.size(), g_devtools_lifecycle.liveCount(),
                g_devtools_lifecycle.pendingCount());
        return 0;
    }

    g_browsers.clear();
    g_cef_to_handle.clear();
    g_callbacks.clear();
    g_clients.clear();
    g_devtools_client = nullptr;
    g_devtools_requested_handles.clear();

    CefShutdown();
    g_app = nullptr;
    g_initialized = false;
    fprintf(stderr, "[CEFBridge] Shutdown complete\n");
    return 1;
}

void* cef_bridge_get_browser_view(CEFBrowserHandle browser) {
    auto b = getBrowser(browser);
    if (b) {
        return b->GetHost()->GetWindowHandle();
    }
    return nullptr;
}

void cef_bridge_resize_browser(CEFBrowserHandle browser, int width, int height) {
    auto b = getBrowser(browser);
    if (b) {
        CefWindowHandle handle = b->GetHost()->GetWindowHandle();
        if (handle) {
            NSView* view = (__bridge NSView*)handle;
            [view setFrameSize:NSMakeSize(width, height)];
        }
    }
}

void cef_bridge_open_devtools(CEFBrowserHandle browser, void* parentView) {
    auto b = getBrowser(browser);
    if (!b) return;

    CefWindowInfo windowInfo;
    if (parentView) {
        NSView* parent = (__bridge NSView*)parentView;
        NSRect frame = parent.bounds;
        CefRect cef_rect(0, 0, (int)frame.size.width, (int)frame.size.height);
        windowInfo.SetAsChild(parentView, cef_rect);
    }

    auto host = b->GetHost();
    if (host->HasDevTools()) return;
    const intptr_t handle = (intptr_t)browser;
    if (!g_devtools_requested_handles.insert(handle).second) return;
    g_devtools_lifecycle.beginCreate();
    if (!g_devtools_client) g_devtools_client = new ChromiumDevToolsClient();

    CefBrowserSettings settings;
    host->ShowDevTools(windowInfo, g_devtools_client, settings, CefPoint());
    fprintf(stderr, "[CEFBridge] DevTools opened (embedded=%s)\n", parentView ? "yes" : "no");
}

void cef_bridge_close_devtools(CEFBrowserHandle browser) {
    auto b = getBrowser(browser);
    if (!b) return;
    b->GetHost()->CloseDevTools();
    fprintf(stderr, "[CEFBridge] DevTools closed\n");
}
