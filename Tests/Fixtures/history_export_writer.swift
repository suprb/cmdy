import Darwin
import Foundation

@main struct RouteWriter {
    static func main() {
        do {
            let arguments = CommandLine.arguments
            let mode = arguments[1]
            if mode == "foundation" {
                FileHandle.standardOutput.write(Data(FileManager.default.temporaryDirectory.path.utf8))
                return
            }
            if mode == "resolve" {
                let environment: [String: String] = arguments.count == 3 ? ["TMPDIR": arguments[2]] : [:]
                let directory = try TerminalTextFile.temporaryDirectory(environment: environment)
                FileHandle.standardOutput.write(Data(directory.path.utf8))
                return
            }
            let text = try String(contentsOfFile: arguments[2], encoding: .utf8)
            let path: URL
            if mode == "explicit" {
                path = try TerminalTextFile.write(text, directory: URL(fileURLWithPath: arguments[3], isDirectory: true))
            } else {
                guard mode == "default" else { throw POSIXError(.EINVAL) }
                path = try TerminalTextFile.write(text)
            }
            FileHandle.standardOutput.write(Data(path.path.utf8))
        } catch {
            FileHandle.standardError.write(Data("owned-export-failed\n".utf8))
            exit(1)
        }
    }
}
