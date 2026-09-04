import AppKit
import ChromiumSupport
import ProductIdentity
import Darwin
import CmdyKit

private typealias CEFViewCreatedCallback = @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
) -> Void
private typealias CEFPageLoadedCallback = @convention(c) (
    UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?
) -> Void
private typealias CEFConsoleCallback = @convention(c) (
    UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?,
    Int32, UnsafeMutableRawPointer?
) -> Void
private typealias CEFBrowserClosedCallback = @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
) -> Void

private struct EmbeddedCEFFunctions {
    typealias LoadLibrary = @convention(c) (UnsafePointer<CChar>?) -> Int32
    typealias Initialize = @convention(c) (
        UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?
    ) -> Int32
    typealias MessageLoopWork = @convention(c) () -> Void
    typealias CreateBrowser = @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<CChar>?,
        CEFViewCreatedCallback?, CEFPageLoadedCallback?, CEFConsoleCallback?,
        CEFBrowserClosedCallback?,
        UnsafeMutableRawPointer?
    ) -> UnsafeMutableRawPointer?
    typealias Navigate = @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<CChar>?
    ) -> Void
    typealias BrowserAction = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias BrowserViewAction = @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
    ) -> Void
    typealias ExecuteJavaScript = @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<CChar>?
    ) -> Void
    typealias GetString = @convention(c) (
        UnsafeMutableRawPointer?
    ) -> UnsafeMutablePointer<CChar>?
    typealias Resize = @convention(c) (
        UnsafeMutableRawPointer?, Int32, Int32
    ) -> Void
    typealias Shutdown = @convention(c) (Int32) -> Int32

    let loadLibrary: LoadLibrary
    let initialize: Initialize
    let messageLoopWork: MessageLoopWork
    let createBrowser: CreateBrowser
    let navigate: Navigate
    let reload: BrowserAction
    let goBack: BrowserAction
    let goForward: BrowserAction
    let executeJavaScript: ExecuteJavaScript
    let getURL: GetString
    let closeBrowser: BrowserAction
    let resizeBrowser: Resize
    let openDevTools: BrowserViewAction
    let shutdown: Shutdown
}

private enum EmbeddedChromiumError: LocalizedError {
    case missingPayload(String)
    case loadFailed(String)
    case missingSymbol(String)
    case frameworkFailed
    case initializationFailed

    var errorDescription: String? {
        switch self {
        case .missingPayload(let name):
            return "Browser is missing \(name)"
        case .loadFailed(let detail):
            return "Browser host could not load: \(detail)"
        case .missingSymbol(let name):
            return "Browser host is missing \(name)"
        case .frameworkFailed:
            return "Chromium Embedded Framework could not load"
        case .initializationFailed:
            return "Chromium Embedded Framework could not initialize"
        }
    }
}

/// Optional Chromium runtime activated by the removable Browser Extension.
/// The framework and sandbox helpers stay sealed inside cmdy.app, but the
/// Swift app has no static CEF linkage and loads them only after Browser is
/// enabled. The visible CEF view is a real child of cmdy's center split.
final class EmbeddedChromiumRuntime {
    static let shared = EmbeddedChromiumRuntime()
    static let applicationTerminationWaitMilliseconds: Int32 = 0

    private var extensionDirectory: URL?
    private var libraryHandle: UnsafeMutableRawPointer?
    private var functions: EmbeddedCEFFunctions?
    private var messagePump: Timer?
    private var sessions: [CGWindowID: EmbeddedChromiumSession] = [:]
    private var initialized = false
    private var enabled = false
    private var apiRunning = false

    private lazy var browserAPI = BrowserAPI(
        operations: ChromiumBrowserOperations(
            executeJavaScript: { [weak self] browser, code in
                self?.executeJavaScript(browser, code)
            },
            reload: { [weak self] browser in self?.functions?.reload(browser) },
            goBack: { [weak self] browser in self?.functions?.goBack(browser) },
            goForward: { [weak self] browser in self?.functions?.goForward(browser) },
            currentURL: { [weak self] browser in self?.currentURL(for: browser) ?? "" }
        ))

    var isAvailable: Bool { enabled && extensionDirectory != nil }

    private init() {}

    private var cacheDirectory: URL {
        if let path = ProductIdentity.current.environmentValue("CHROMIUM_CACHE"),
           !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
                .standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                ".cache/\(ProductIdentity.current.slug)-chromium-embedded",
                isDirectory: true)
    }

    private struct RuntimeLayout {
        let dylib: URL
        let framework: URL
        let helper: URL
        let frameworksDirectory: URL
    }

    private func bundledRuntimeLayout() -> RuntimeLayout {
        let frameworksDirectory = Bundle.main.privateFrameworksURL
            ?? Bundle.main.bundleURL.appendingPathComponent(
                "Contents/Frameworks", isDirectory: true)
        let helperName = "\(ProductIdentity.current.titleName) Chromium Helper"
        return RuntimeLayout(
            dylib: frameworksDirectory.appendingPathComponent(
                "libCmdyChromiumHost.dylib"),
            framework: frameworksDirectory.appendingPathComponent(
                "Chromium Embedded Framework.framework/Chromium Embedded Framework"),
            helper: frameworksDirectory.appendingPathComponent(
                "\(helperName).app/Contents/MacOS/\(helperName)"),
            frameworksDirectory: frameworksDirectory)
    }

    private func isComplete(_ layout: RuntimeLayout) -> Bool {
        FileManager.default.fileExists(atPath: layout.dylib.path)
            && FileManager.default.fileExists(atPath: layout.framework.path)
            && FileManager.default.isExecutableFile(atPath: layout.helper.path)
    }

    private func runtimeLayout(in directory: URL) -> RuntimeLayout {
        // Keep legacy Browser-edition apps working during migration.
        let bundled = bundledRuntimeLayout()
        if isComplete(bundled) { return bundled }

        // Source/ad-hoc development keeps the legacy flat Extension layout.
        return RuntimeLayout(
            dylib: directory.appendingPathComponent(
                "libCmdyChromiumHost.dylib"),
            framework: directory.appendingPathComponent(
                "Frameworks/Chromium Embedded Framework.framework/Chromium Embedded Framework"),
            helper: directory.appendingPathComponent("chromium"),
            frameworksDirectory: directory.appendingPathComponent(
                "Frameworks", isDirectory: true))
    }

    /// Compatibility builds activate their sealed, bundled runtime when an old
    /// Browser-edition install cannot create its removable Extension record.
    @discardableResult
    func enableBundledRuntimeIfPresent() -> Bool {
        precondition(Thread.isMainThread)
        let layout = bundledRuntimeLayout()
        guard isComplete(layout) else { return false }
        return setEnabled(true, directory: Bundle.main.bundleURL)
    }

    @discardableResult
    func setEnabled(_ shouldEnable: Bool, directory: URL) -> Bool {
        precondition(Thread.isMainThread)
        if shouldEnable {
            let layout = runtimeLayout(in: directory)
            guard FileManager.default.fileExists(atPath: layout.dylib.path),
                  FileManager.default.fileExists(atPath: layout.framework.path),
                  FileManager.default.isExecutableFile(atPath: layout.helper.path) else {
                return false
            }
            extensionDirectory = directory
            enabled = true
            configureBrowserAPI()
            NotificationCenter.default.post(
                name: .cmdyEmbeddedChromiumAvailabilityChanged, object: self)
            return true
        }

        enabled = false
        if apiRunning {
            browserAPI.stop()
            apiRunning = false
        }
        closeAllBrowsers()
        NotificationCenter.default.post(
            name: .cmdyEmbeddedChromiumAvailabilityChanged, object: self)
        return true
    }

    func shutdown() {
        precondition(Thread.isMainThread)
        if apiRunning {
            browserAPI.stop()
            apiRunning = false
        }
        closeAllBrowsers()
        messagePump?.invalidate()
        messagePump = nil
        // Application termination must never spin the AppKit main thread for
        // CEF's old ten-second close deadline. Request closure and shut down
        // immediately only when CEF has no live lifecycle left; otherwise the
        // process exit safely releases the already-unlinked framework.
        if initialized,
           functions?.shutdown(Self.applicationTerminationWaitMilliseconds) == 1 {
            initialized = false
        } else if initialized {
            // CEF explicitly refused an unsafe shutdown. Keep the dylib loaded;
            // process teardown is safer than dlclosing live browser objects.
            NSLog("embedded chromium: deferred shutdown to process exit")
            return
        }
        functions = nil
        if let libraryHandle { dlclose(libraryHandle) }
        libraryHandle = nil
    }

    private func configureBrowserAPI() {
        browserAPI.ensureBrowser = { [weak self] windowNumber in
            guard let self, let controller = self.controller(for: windowNumber),
                  controller.showEmbeddedBrowser() else { return nil }
            return controller.embeddedBrowserHandle
        }
        browserAPI.navigateBrowser = { [weak self] address, windowNumber in
            guard let self, let url = self.normalizedAddress(address),
                  let controller = self.controller(for: windowNumber),
                  controller.showEmbeddedBrowser(url: url) else { return false }
            return true
        }
        browserAPI.windowForScreenshot = { [weak self] windowNumber in
            self?.controller(for: windowNumber)?.window
        }
        browserAPI.screenshotCropRect = { [weak self] windowNumber in
            self?.controller(for: windowNumber)?.embeddedBrowserCaptureRect
        }
        browserAPI.screenshotDone = { _ in }
        if !apiRunning {
            browserAPI.start()
            apiRunning = browserAPI.port > 0
        }
    }

    private func controller(for windowNumber: CGWindowID?) -> TerminalWindowController? {
        guard let app = NSApp.delegate as? AppDelegate else { return nil }
        if let windowNumber {
            return app.allControllers.first {
                $0.window?.windowNumber == Int(windowNumber)
            }
        }
        return app.currentController
    }

    func openBrowser(
        in hostView: EmbeddedChromiumHostView,
        windowNumber: CGWindowID,
        initialURL: String,
        onPageLoaded: @escaping (String) -> Void
    ) -> EmbeddedChromiumSession? {
        precondition(Thread.isMainThread)
        guard enabled else { return nil }
        if let existing = sessions[windowNumber] {
            existing.hostView = hostView
            existing.onPageLoaded = onPageLoaded
            existing.resize()
            return existing
        }
        do {
            try ensureInitialized()
        } catch {
            NSLog("embedded chromium: %@", error.localizedDescription)
            return nil
        }
        guard let functions else { return nil }
        let session = EmbeddedChromiumSession(
            runtime: self, hostView: hostView, windowNumber: windowNumber,
            onPageLoaded: onPageLoaded)
        // The bridge owns this retain until its explicit OnBeforeClose callback.
        // A close racing asynchronous creation therefore cannot free the context.
        let context = Unmanaged.passRetained(session).toOpaque()
        let parent = Unmanaged.passUnretained(hostView).toOpaque()
        let browser = initialURL.withCString {
            functions.createBrowser(
                parent, $0, nil, embeddedChromiumPageLoaded,
                embeddedChromiumConsoleMessage, embeddedChromiumClosed, context)
        }
        guard let browser else {
            Unmanaged<EmbeddedChromiumSession>.fromOpaque(context).release()
            return nil
        }
        session.browser = browser
        hostView.session = session
        sessions[windowNumber] = session
        session.resize()
        return session
    }

    func closeBrowser(windowNumber: CGWindowID) {
        precondition(Thread.isMainThread)
        guard let session = sessions.removeValue(forKey: windowNumber) else { return }
        if let browser = session.browser { functions?.closeBrowser(browser) }
        session.browser = nil
        session.hostView?.session = nil
    }

    fileprivate func browserDidClose(_ session: EmbeddedChromiumSession) {
        precondition(Thread.isMainThread)
        if sessions[session.windowNumber] === session {
            sessions.removeValue(forKey: session.windowNumber)
        }
        session.browser = nil
        if session.hostView?.session === session {
            session.hostView?.session = nil
        }
    }

    private func closeAllBrowsers() {
        for windowNumber in Array(sessions.keys) {
            closeBrowser(windowNumber: windowNumber)
        }
    }

    func navigate(_ browser: ChromiumBrowserHandle, to address: String) {
        guard let normalized = normalizedAddress(address) else { return }
        normalized.withCString { functions?.navigate(browser, $0) }
    }

    func reload(_ browser: ChromiumBrowserHandle) { functions?.reload(browser) }
    func goBack(_ browser: ChromiumBrowserHandle) { functions?.goBack(browser) }
    func goForward(_ browser: ChromiumBrowserHandle) { functions?.goForward(browser) }
    func openDevTools(_ browser: ChromiumBrowserHandle) {
        functions?.openDevTools(browser, nil)
    }

    fileprivate func resize(
        _ browser: ChromiumBrowserHandle, to size: NSSize
    ) {
        let width = Int32(max(1, min(CGFloat(Int32.max), size.width)).rounded())
        let height = Int32(max(1, min(CGFloat(Int32.max), size.height)).rounded())
        functions?.resizeBrowser(browser, width, height)
    }

    fileprivate func consoleMessage(
        _ text: String, source: String, line: Int, windowNumber: CGWindowID
    ) {
        browserAPI.handleConsoleMessage(
            text, source: source, line: line, hostWindow: windowNumber)
    }

    private func executeJavaScript(
        _ browser: ChromiumBrowserHandle, _ code: String
    ) {
        code.withCString { functions?.executeJavaScript(browser, $0) }
    }

    private func currentURL(for browser: ChromiumBrowserHandle) -> String {
        guard let raw = functions?.getURL(browser) else { return "" }
        defer { free(raw) }
        return String(cString: raw)
    }

    private func ensureInitialized() throws {
        if initialized { return }
        guard let extensionDirectory else {
            throw EmbeddedChromiumError.missingPayload("Extension directory")
        }
        let layout = runtimeLayout(in: extensionDirectory)
        for url in [layout.dylib, layout.framework, layout.helper]
        where !FileManager.default.fileExists(atPath: url.path) {
            throw EmbeddedChromiumError.missingPayload(url.lastPathComponent)
        }

        let handle: UnsafeMutableRawPointer
        if let libraryHandle {
            handle = libraryHandle
        } else {
            guard let loaded = dlopen(layout.dylib.path, RTLD_NOW | RTLD_LOCAL) else {
                let detail = dlerror().map { String(cString: $0) } ?? "unknown error"
                throw EmbeddedChromiumError.loadFailed(detail)
            }
            libraryHandle = loaded
            handle = loaded
        }
        let loadedFunctions = try loadFunctions(from: handle)
        guard layout.framework.path.withCString({
            loadedFunctions.loadLibrary($0)
        }) == 1 else {
            throw EmbeddedChromiumError.frameworkFailed
        }
        let cache = cacheDirectory
        try? FileManager.default.createDirectory(
            at: cache, withIntermediateDirectories: true)
        let didInitialize = layout.helper.path.withCString { helperPath in
            cache.path.withCString { cachePath in
                layout.frameworksDirectory.path.withCString { frameworksPath in
                    loadedFunctions.initialize(
                        helperPath, cachePath, frameworksPath)
                }
            }
        }
        guard didInitialize == 1 else {
            throw EmbeddedChromiumError.initializationFailed
        }
        functions = loadedFunctions
        initialized = true
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) {
            [weak self] _ in self?.functions?.messageLoopWork()
        }
        RunLoop.main.add(timer, forMode: .common)
        messagePump = timer
    }

    private func loadFunctions(
        from handle: UnsafeMutableRawPointer
    ) throws -> EmbeddedCEFFunctions {
        func symbol<T>(_ name: String, as type: T.Type) throws -> T {
            guard let raw = dlsym(handle, name) else {
                throw EmbeddedChromiumError.missingSymbol(name)
            }
            return unsafeBitCast(raw, to: type)
        }
        return try EmbeddedCEFFunctions(
            loadLibrary: symbol(
                "cef_bridge_load_library", as: EmbeddedCEFFunctions.LoadLibrary.self),
            initialize: symbol(
                "cmdy_cef_bridge_init_with_framework",
                as: EmbeddedCEFFunctions.Initialize.self),
            messageLoopWork: symbol(
                "cef_bridge_do_message_loop_work",
                as: EmbeddedCEFFunctions.MessageLoopWork.self),
            createBrowser: symbol(
                "cef_bridge_create_browser_v2",
                as: EmbeddedCEFFunctions.CreateBrowser.self),
            navigate: symbol(
                "cef_bridge_navigate", as: EmbeddedCEFFunctions.Navigate.self),
            reload: symbol(
                "cef_bridge_reload", as: EmbeddedCEFFunctions.BrowserAction.self),
            goBack: symbol(
                "cef_bridge_go_back", as: EmbeddedCEFFunctions.BrowserAction.self),
            goForward: symbol(
                "cef_bridge_go_forward", as: EmbeddedCEFFunctions.BrowserAction.self),
            executeJavaScript: symbol(
                "cef_bridge_execute_js",
                as: EmbeddedCEFFunctions.ExecuteJavaScript.self),
            getURL: symbol(
                "cef_bridge_get_url", as: EmbeddedCEFFunctions.GetString.self),
            closeBrowser: symbol(
                "cef_bridge_close_browser",
                as: EmbeddedCEFFunctions.BrowserAction.self),
            resizeBrowser: symbol(
                "cef_bridge_resize_browser", as: EmbeddedCEFFunctions.Resize.self),
            openDevTools: symbol(
                "cef_bridge_open_devtools",
                as: EmbeddedCEFFunctions.BrowserViewAction.self),
            shutdown: symbol(
                "cef_bridge_shutdown_and_wait",
                as: EmbeddedCEFFunctions.Shutdown.self))
    }

    private func normalizedAddress(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.range(
            of: #"^(?:https?|file|about):"#,
            options: [.regularExpression, .caseInsensitive]) != nil {
            return value
        }
        if value.range(
            of: #"^(?:localhost|127\.0\.0\.1|\[::1\])(?::\d+)?(?:/|$)"#,
            options: [.regularExpression, .caseInsensitive]) != nil {
            return "http://" + value
        }
        if !value.contains(" "), value.contains(".") {
            return "https://" + value
        }
        guard let query = value.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed) else { return nil }
        return "https://www.google.com/search?q=\(query)"
    }

    var startPageURL: String {
        BrowserStartPage.install(in: cacheDirectory.path)
    }
}

private func embeddedChromiumPageLoaded(
    _ browser: UnsafeMutableRawPointer?, _ url: UnsafePointer<CChar>?,
    _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let session = Unmanaged<EmbeddedChromiumSession>
        .fromOpaque(context).takeUnretainedValue()
    session.pageLoaded(url.map { String(cString: $0) } ?? "")
}

private func embeddedChromiumConsoleMessage(
    _ browser: UnsafeMutableRawPointer?, _ message: UnsafePointer<CChar>?,
    _ source: UnsafePointer<CChar>?, _ line: Int32,
    _ context: UnsafeMutableRawPointer?
) {
    guard let context, let message else { return }
    let session = Unmanaged<EmbeddedChromiumSession>
        .fromOpaque(context).takeUnretainedValue()
    session.runtime.consoleMessage(
        String(cString: message),
        source: source.map { String(cString: $0) } ?? "",
        line: Int(line), windowNumber: session.windowNumber)
}

private func embeddedChromiumClosed(
    _ browser: UnsafeMutableRawPointer?, _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let session = Unmanaged<EmbeddedChromiumSession>
        .fromOpaque(context).takeRetainedValue()
    session.runtime.browserDidClose(session)
}

final class EmbeddedChromiumSession {
    fileprivate unowned let runtime: EmbeddedChromiumRuntime
    fileprivate weak var hostView: EmbeddedChromiumHostView?
    fileprivate let windowNumber: CGWindowID
    fileprivate var browser: ChromiumBrowserHandle?
    fileprivate var onPageLoaded: (String) -> Void
    private var lastSize = NSSize.zero

    fileprivate init(
        runtime: EmbeddedChromiumRuntime,
        hostView: EmbeddedChromiumHostView,
        windowNumber: CGWindowID,
        onPageLoaded: @escaping (String) -> Void
    ) {
        self.runtime = runtime
        self.hostView = hostView
        self.windowNumber = windowNumber
        self.onPageLoaded = onPageLoaded
    }

    fileprivate func pageLoaded(_ url: String) {
        onPageLoaded(url)
    }

    fileprivate func resize() {
        guard let browser, let size = hostView?.bounds.size,
              size.width > 0, size.height > 0, size != lastSize else { return }
        lastSize = size
        runtime.resize(browser, to: size)
    }
}

final class EmbeddedChromiumHostView: NSView {
    fileprivate weak var session: EmbeddedChromiumSession?

    override func layout() {
        super.layout()
        session?.resize()
    }
}

/// One per terminal window. It owns only the AppKit parent view and a CEF
/// browser handle; the runtime/framework is shared across all windows.
final class EmbeddedChromiumViewController: NSViewController {
    private let browserHost = EmbeddedChromiumHostView(frame: .zero)
    private var browserHostTopConstraint: NSLayoutConstraint?
    private var session: EmbeddedChromiumSession?
    private var chromeTheme = Preferences.shared.theme
    var chromeBackground: TermColor { chromeTheme.background }
    private(set) var lastLoadedURL = ""
    var onPageLoaded: ((String) -> Void)?
    var topContentInset: CGFloat = 0 {
        didSet {
            let normalized = max(0, topContentInset)
            guard abs(normalized - max(0, oldValue)) > 0.25 else { return }
            browserHostTopConstraint?.constant = normalized
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
        }
    }

    var browserHandle: ChromiumBrowserHandle? { session?.browser }
    var isAttachedToCmdyWindow: Bool {
        browserHost.window != nil && browserHost.window === view.window
    }
    var nativeBrowserSubviewCount: Int { browserHost.subviews.count }
    var layoutDiagnostic: (
        cornerRadius: CGFloat, masksToBounds: Bool,
        topGap: CGFloat, bottomGap: CGFloat, horizontalGap: CGFloat
    ) {
        loadViewIfNeeded()
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        let frame = browserHost.frame
        return (
            cornerRadius: view.layer?.cornerRadius ?? 0,
            masksToBounds: view.layer?.masksToBounds ?? false,
            topGap: max(0, bounds.maxY - frame.maxY),
            bottomGap: abs(frame.minY - bounds.minY),
            horizontalGap: max(
                abs(frame.minX - bounds.minX),
                abs(frame.maxX - bounds.maxX)))
    }
    var captureRectInWindow: NSRect? {
        guard let window = browserHost.window else { return nil }
        let browserRect = browserHost.convert(browserHost.bounds, to: nil)
        let visibleRect = window.contentView.map {
            $0.convert($0.bounds, to: nil)
        } ?? NSRect(origin: .zero, size: window.frame.size)
        return browserRect.intersection(visibleRect)
    }

    override func loadView() {
        let root = NSView(frame: .zero)
        root.wantsLayer = true
        root.layer?.cornerRadius = 0
        root.layer?.masksToBounds = false
        browserHost.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(browserHost)
        browserHostTopConstraint = browserHost.topAnchor.constraint(
            equalTo: root.topAnchor, constant: max(0, topContentInset))
        NSLayoutConstraint.activate([
            browserHost.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            browserHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            browserHostTopConstraint!,
            browserHost.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        applyTheme(chromeTheme)
    }

    @discardableResult
    func ensureBrowser(windowNumber: CGWindowID, initialURL: String?) -> Bool {
        loadViewIfNeeded()
        if session == nil {
            session = EmbeddedChromiumRuntime.shared.openBrowser(
                in: browserHost, windowNumber: windowNumber,
                initialURL: initialURL
                    ?? EmbeddedChromiumRuntime.shared.startPageURL
            ) { [weak self] url in
                self?.lastLoadedURL = url
                self?.onPageLoaded?(url)
            }
        } else if let initialURL, let browser = session?.browser {
            EmbeddedChromiumRuntime.shared.navigate(browser, to: initialURL)
        }
        return session?.browser != nil
    }

    func navigate(to address: String) {
        guard let browser = session?.browser else { return }
        EmbeddedChromiumRuntime.shared.navigate(browser, to: address)
    }

    func reload() {
        if let browser = session?.browser {
            EmbeddedChromiumRuntime.shared.reload(browser)
        }
    }

    func goBack() {
        if let browser = session?.browser {
            EmbeddedChromiumRuntime.shared.goBack(browser)
        }
    }

    func goForward() {
        if let browser = session?.browser {
            EmbeddedChromiumRuntime.shared.goForward(browser)
        }
    }

    func openDevTools() {
        if let browser = session?.browser {
            EmbeddedChromiumRuntime.shared.openDevTools(browser)
        }
    }

    func close(windowNumber: CGWindowID) {
        EmbeddedChromiumRuntime.shared.closeBrowser(windowNumber: windowNumber)
        session = nil
    }

    func applyTheme(_ theme: Theme) {
        chromeTheme = theme
        loadViewIfNeeded()
        let background = chromeTheme.ns(chromeTheme.background)
        view.layer?.backgroundColor = background.cgColor
    }
}

extension Notification.Name {
    static let cmdyEmbeddedChromiumAvailabilityChanged = Notification.Name(
        "cmdy.embeddedChromiumAvailabilityChanged")
}
