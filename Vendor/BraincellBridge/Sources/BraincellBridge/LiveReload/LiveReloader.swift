import Foundation

/// Per-project live-reload coordinator. One `FileWatcher` per unique
/// `projectPath` (sibling sessions in the same project share a `ChromeAdapter`,
/// so they share the watcher too — otherwise an edit would trigger N reloads).
/// On debounced batch:
///
/// - **CSS-only batch** → call `ChromeAdapter.hotReloadCSS` to bump link
///   cache-busters in place. Page state (scroll, form input, JS state) is
///   preserved.
/// - **Anything else** (HTML/JS/TS/JSON/asset) → full `Page.reload` via CDP.
///
/// If hot-swap reports zero matched links (CSS that isn't `<link>`-referenced
/// — e.g. inlined `<style>` blocks or imported via JS), fall back to full
/// reload. So the user never sees "I edited and nothing happened."
///
/// CSS is treated as a simple in-place update; larger code or document
/// changes trigger a full reload.
@MainActor
final class LiveReloader {
    /// AppDelegate sets this so the reloader can resolve a sessionId →
    /// ChromeAdapter without owning a reference to the full state container.
    var adapterFor: ((String) -> ChromeAdapter?)?

    private var sessionPaths: [String: String] = [:]      // sessionId → projectPath
    private var watcherPerPath: [String: FileWatcher] = [:] // projectPath → watcher

    /// Begin live-reload for a bound session. Idempotent. If another session
    /// already covers `projectPath` (sibling in same project), reuses the
    /// existing watcher — only one FileWatcher per project path.
    func start(sessionId: String, projectPath: String) {
        stop(sessionId: sessionId)
        sessionPaths[sessionId] = projectPath
        if watcherPerPath[projectPath] != nil { return }
        let w = FileWatcher()
        w.onFilesChanged = { [weak self] changes in
            Task { @MainActor [weak self] in
                self?.dispatch(projectPath: projectPath, changes: changes)
            }
        }
        w.watch(path: projectPath)
        watcherPerPath[projectPath] = w
    }

    /// Tear down live-reload for `sessionId`. The underlying watcher is only
    /// stopped when the last session referencing its path goes away.
    func stop(sessionId: String) {
        guard let path = sessionPaths.removeValue(forKey: sessionId) else { return }
        let stillUsed = sessionPaths.values.contains(path)
        if !stillUsed {
            watcherPerPath[path]?.stop()
            watcherPerPath.removeValue(forKey: path)
        }
    }

    func stopAll() {
        for w in watcherPerPath.values { w.stop() }
        watcherPerPath.removeAll()
        sessionPaths.removeAll()
    }

    // MARK: - Dispatch

    private func dispatch(projectPath: String, changes: Set<String>) {
        // Pick any session bound to this path — siblings share an adapter,
        // so any sessionId on this path resolves to the right Chrome.
        guard let sid = sessionPaths.first(where: { $0.value == projectPath })?.key,
              let adapter = adapterFor?(sid) else {
            NSLog("[LiveReload] no adapter for path %@; dropping batch", projectPath)
            return
        }

        let exts = Set(changes.map { ($0 as NSString).pathExtension.lowercased() })

        // CSS-only batch: try hot-swap first. If zero links matched, fall
        // back to full reload (rare — usually means the CSS isn't linked
        // via <link> on the current page).
        if !exts.isEmpty && exts.isSubset(of: ["css"]) {
            let names = changes.map { ($0 as NSString).lastPathComponent }
            NSLog("[LiveReload] CSS hot-swap for %@: %@", projectPath, names.joined(separator: ", "))
            Task { @MainActor [weak self] in
                let swapped = await adapter.hotReloadCSS(filenames: names)
                if swapped == 0 {
                    NSLog("[LiveReload] no <link> matched; falling back to full reload")
                    self?.fullReload(adapter: adapter)
                } else {
                    NSLog("[LiveReload] swapped %d stylesheet(s)", swapped)
                }
            }
            return
        }

        NSLog("[LiveReload] full reload for %@ (extensions: %@)",
              projectPath, exts.sorted().joined(separator: ","))
        fullReload(adapter: adapter)
    }

    private func fullReload(adapter: ChromeAdapter) {
        Task { try? await adapter.reload(ignoreCache: false) }
    }
}
