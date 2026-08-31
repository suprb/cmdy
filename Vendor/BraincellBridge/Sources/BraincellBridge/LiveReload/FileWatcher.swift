import Foundation

/// FSEvents-based directory tree watcher with a deliberately small callback
/// surface.
///
/// One watcher per bound session — the bridge's `LiveReloader` creates
/// it on bind, tears it down on unbind. Recursively monitors `projectPath`
/// up to `maxMonitors` directories (FD-cap defense), debounces 800ms so
/// Claude's burst writes coalesce into one reload.
final class FileWatcher {
    private var directoryMonitors: [String: DispatchSourceFileSystemObject] = [:]
    private var debounceTimer: DispatchSourceTimer?
    private var pendingChanges: Set<String> = []
    private let queue = DispatchQueue(label: "com.braincell.bridge.filewatcher")

    var projectPath: String?

    /// Called with the set of changed file paths after the debounce window.
    /// Use file extensions to decide reload strategy (CSS-only vs full reload).
    var onFilesChanged: ((Set<String>) -> Void)?

    private let watchedExtensions: Set<String> = [
        "html", "css", "js", "jsx", "ts", "tsx", "json", "svg", "png", "jpg", "gif", "webp",
    ]

    private let ignoredDirs: Set<String> = [
        "node_modules", ".git", "dist", "build", ".next", ".nuxt", "__pycache__",
        ".braincell", ".claude", ".build", ".vite", ".turbo", "target", "vendor",
    ]

    /// FD cap — opening too many file descriptors will eventually trip the
    /// per-process limit. 50 dirs is plenty for typical projects.
    private let maxMonitors = 50

    func watch(path: String) {
        stop()
        projectPath = path
        startWatching(directory: path)
        NSLog("[LiveReload] Watching %@ (%d dirs)", path, directoryMonitors.count)
    }

    func stop() {
        for (_, source) in directoryMonitors {
            source.cancel()
        }
        directoryMonitors.removeAll()
        debounceTimer?.cancel()
        debounceTimer = nil
        pendingChanges.removeAll()
    }

    private func startWatching(directory: String) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: directory),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        monitorDirectory(directory)

        while let url = enumerator.nextObject() as? URL {
            guard directoryMonitors.count < maxMonitors else { break }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let name = url.lastPathComponent
            if isDir {
                if ignoredDirs.contains(name) {
                    enumerator.skipDescendants()
                    continue
                }
                monitorDirectory(url.path)
            }
        }
    }

    private func monitorDirectory(_ path: String) {
        guard directoryMonitors[path] == nil else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.handleDirectoryChange(path)
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        directoryMonitors[path] = source
    }

    private func handleDirectoryChange(_ directory: String) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: directory) else { return }

        for file in contents {
            let ext = (file as NSString).pathExtension.lowercased()
            if watchedExtensions.contains(ext) {
                let fullPath = (directory as NSString).appendingPathComponent(file)
                pendingChanges.insert(fullPath)
            }
        }

        // Debounce: wait 800ms for more changes (Claude writes files in bursts).
        debounceTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(800))
        timer.setEventHandler { [weak self] in
            self?.flushChanges()
        }
        timer.resume()
        debounceTimer = timer
    }

    private func flushChanges() {
        let changes = pendingChanges
        pendingChanges.removeAll()
        guard !changes.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onFilesChanged?(changes)
        }
    }
}
