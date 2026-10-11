import CmdyKit
import Foundation

/// Deliver the visible screen's path only after its private file is complete.
enum TerminalScreenExport {
    @discardableResult
    static func write(from engine: TerminalEngine,
                      filename: String,
                      environment: [String: String] = ProcessInfo.processInfo.environment,
                      deliver: (URL) -> Void) throws -> URL {
        let text = (0..<engine.rows).compactMap {
            engine.scrollbackLineText(row: engine.currentTopRow + $0)
        }.joined(separator: "\n") + "\n"
        let directory = try TerminalTextFile.temporaryDirectory(environment: environment)
        let url = try TerminalTextFile.write(text, directory: directory, filename: filename)
        deliver(url)
        return url
    }
}
