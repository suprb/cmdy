import CmdyKit
import Foundation

/// The public export action sends a completed private file's path directly to
/// the requesting terminal. It does not select text or access a pasteboard.
enum TerminalScrollbackExport {
    @discardableResult
    static func paste(from engine: TerminalEngine,
                      directory: URL? = nil,
                      sendPath: (String) -> Void) throws -> URL {
        let url = try TerminalTextFile.write(engine.scrollbackText(), directory: directory)
        sendPath(url.path)
        return url
    }
}
