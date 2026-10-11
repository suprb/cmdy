import Darwin
import Foundation

/// An explicitly requested export is private from its first byte. The directory
/// descriptor anchors exclusive creation and cleanup without following a leaf symlink.
enum TerminalTextFile {
    static func write(_ text: String, directory: URL? = nil,
                      filename: String = "cmdy-scrollback-\(UUID().uuidString).txt") throws -> URL {
        let directory = try directory ?? temporaryDirectory()
        guard directory.isFileURL, !filename.isEmpty, filename != ".", filename != "..",
              !filename.contains("/"), !filename.utf8.contains(0) else { throw POSIXError(.EINVAL) }
        let directoryDescriptor = directory.path.withCString { path in
            open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard directoryDescriptor >= 0 else { throw currentError() }
        defer { close(directoryDescriptor) }
        let descriptor = openat(directoryDescriptor, filename, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                                mode_t(0o600))
        guard descriptor >= 0 else { throw currentError() }
        var created = stat()
        guard fstat(descriptor, &created) == 0 else {
            let error = currentError(); close(descriptor); throw error
        }
        var isOpen = true
        defer { if isOpen { close(descriptor) } }
        do {
            // A restrictive caller umask may remove owner bits; it can never
            // expose data, and the finished file has the exact private mode.
            guard fchmod(descriptor, mode_t(0o600)) == 0 else { throw currentError() }
            try Data(text.utf8).withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else { throw written == 0 ? POSIXError(.EIO) : currentError() }
                    offset += written
                }
            }
            let result = close(descriptor)
            isOpen = false
            guard result == 0 else { throw currentError() }
            return directory.appendingPathComponent(filename)
        } catch {
            // Do not remove another file if the created directory entry changed.
            var current = stat()
            if fstatat(directoryDescriptor, filename, &current, AT_SYMLINK_NOFOLLOW) == 0,
               current.st_dev == created.st_dev, current.st_ino == created.st_ino {
                unlinkat(directoryDescriptor, filename, 0)
            }
            throw error
        }
    }

    // Foundation can ignore TMPDIR on macOS. An explicit process directory
    // must remain authoritative; failure must not create a file elsewhere.
    static func temporaryDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        guard let path = environment["TMPDIR"] else { return FileManager.default.temporaryDirectory }
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw POSIXError(.EINVAL) }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func currentError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
