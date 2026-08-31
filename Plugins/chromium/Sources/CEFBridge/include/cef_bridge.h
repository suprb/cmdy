// cef_bridge.h — Thin C API for embedding CEF in a Swift/macOS app.
// Handles ref-counting, struct setup, library loading, and message loop integration.
// Supports multiple browser instances keyed by integer handle.

#ifndef CEF_BRIDGE_H
#define CEF_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdint.h>

/// Opaque handle to a CEF browser instance (integer ID cast to pointer).
typedef void* CEFBrowserHandle;

/// Callback invoked when the browser view (NSView*) is created.
/// handle: the browser handle, nsView: the CEF-created NSView, context: user pointer.
typedef void (*CEFBrowserViewCreatedCallback)(CEFBrowserHandle handle, void* nsView, void* context);

/// Callback invoked when a page finishes loading.
/// handle: the browser handle, url: the loaded URL, context: user pointer.
typedef void (*CEFPageLoadedCallback)(CEFBrowserHandle handle, const char* url, void* context);

/// Callback invoked with console messages.
/// handle: the browser handle, message/source/line: console message details, context: user pointer.
typedef void (*CEFConsoleMessageCallback)(CEFBrowserHandle handle, const char* message, const char* source, int line, void* context);

/// Callback invoked exactly once after CEF has fully closed the browser.
/// This is the ownership boundary for callback context retained by the caller.
typedef void (*CEFBrowserClosedCallback)(CEFBrowserHandle handle, void* context);

/// Load the CEF framework from the given path.
/// Returns 1 on success, 0 on failure.
/// path: absolute path to "Chromium Embedded Framework.framework/Chromium Embedded Framework"
int cef_bridge_load_library(const char* frameworkPath);

/// Initialize CEF. Must be called on the main thread after loading the library.
/// helperPath: path to the helper process executable (or NULL to auto-detect)
/// cachePath: path for browser cache (or NULL for in-memory)
/// Returns 1 on success, 0 on failure.
int cef_bridge_init(const char* helperPath, const char* cachePath);

/// Perform a single iteration of the CEF message loop.
/// Call this from a timer on the main thread (e.g., every 16ms for 60fps).
void cef_bridge_do_message_loop_work(void);

/// Create a browser embedded in the given parent NSView.
/// parentView: the NSView* to embed the browser into
/// url: initial URL to load (or NULL for about:blank)
/// viewCb: callback for when the browser view is created (or NULL)
/// pageCb: callback for when pages finish loading (or NULL)
/// consoleCb: callback for console messages (or NULL)
/// context: user pointer passed to all callbacks
/// Returns a browser handle (integer ID), or NULL on failure.
CEFBrowserHandle cef_bridge_create_browser(void* parentView, const char* url,
                                            CEFBrowserViewCreatedCallback viewCb,
                                            CEFPageLoadedCallback pageCb,
                                            CEFConsoleMessageCallback consoleCb,
                                            void* context);

/// Lifecycle-safe browser creation. New hosts should use this entry point and
/// retain `context` until `closedCb` runs. Close requests issued before CEF's
/// asynchronous OnAfterCreated callback are remembered and completed.
CEFBrowserHandle cef_bridge_create_browser_v2(void* parentView, const char* url,
                                               CEFBrowserViewCreatedCallback viewCb,
                                               CEFPageLoadedCallback pageCb,
                                               CEFConsoleMessageCallback consoleCb,
                                               CEFBrowserClosedCallback closedCb,
                                               void* context);

/// Navigate the browser to a URL.
void cef_bridge_navigate(CEFBrowserHandle browser, const char* url);

/// Reload the current page.
void cef_bridge_reload(CEFBrowserHandle browser);

/// Go back in history.
void cef_bridge_go_back(CEFBrowserHandle browser);

/// Go forward in history.
void cef_bridge_go_forward(CEFBrowserHandle browser);

/// Execute JavaScript in the browser.
void cef_bridge_execute_js(CEFBrowserHandle browser, const char* code);

/// Get the current URL. Caller must free() the returned string.
char* cef_bridge_get_url(CEFBrowserHandle browser);

/// Get the current title. Caller must free() the returned string.
char* cef_bridge_get_title(CEFBrowserHandle browser);

/// Close a browser. The handle becomes invalid after this call.
void cef_bridge_close_browser(CEFBrowserHandle browser);

/// Shut down CEF. Call before app exit.
void cef_bridge_shutdown(void);

/// Close every pending/live browser, pump CEF until OnBeforeClose has run for
/// all of them, and then shut CEF down. Returns 1 on success. On timeout it
/// returns 0 without calling CefShutdown, allowing the process to exit without
/// violating CEF's lifecycle contract.
int cef_bridge_shutdown_and_wait(int timeoutMilliseconds);

/// Number of browser lifecycles that have not reached OnBeforeClose.
int cef_bridge_browser_count(void);

/// Lightweight subprocess entry point. Only calls CefExecuteProcess.
/// Returns the subprocess exit code (>= 0), or -1 if not a subprocess.
int cef_bridge_subprocess_exec(void);

/// Get the browser's NSView* (the CEF-created child view).
void* cef_bridge_get_browser_view(CEFBrowserHandle browser);

/// Resize the browser view to fill its parent.
void cef_bridge_resize_browser(CEFBrowserHandle browser, int width, int height);

/// Open DevTools in the given parent NSView (embedded), or in a new window if parentView is NULL.
void cef_bridge_open_devtools(CEFBrowserHandle browser, void* parentView);

/// Close the DevTools panel.
void cef_bridge_close_devtools(CEFBrowserHandle browser);

#ifdef __cplusplus
}
#endif

#endif // CEF_BRIDGE_H
