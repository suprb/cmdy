import Darwin
import Foundation

/// Current work, rather than the age or scrollback of a shell, determines
/// whether closing it needs confirmation. All terminal close routes use this
/// value; editor save/discard decisions remain owned by the editor.
public struct SessionCloseState: Equatable, Sendable {
    public var runningCommand: String?
    public var runningProcesses: [String]
    public var processStateUnknown: Bool
    public var isAlternateScreen: Bool
    public var hasDraftInput: Bool
    public var hasActiveSurface: Bool

    public init(
        runningCommand: String? = nil,
        runningProcesses: [String] = [],
        processStateUnknown: Bool = false,
        isAlternateScreen: Bool = false,
        hasDraftInput: Bool = false,
        hasActiveSurface: Bool = false
    ) {
        self.runningCommand = runningCommand
        self.runningProcesses = runningProcesses
        self.processStateUnknown = processStateUnknown
        self.isAlternateScreen = isAlternateScreen
        self.hasDraftInput = hasDraftInput
        self.hasActiveSurface = hasActiveSurface
    }

    public var requiresConfirmation: Bool {
        runningCommand != nil || !runningProcesses.isEmpty
            || processStateUnknown || isAlternateScreen || hasDraftInput
            || hasActiveSurface
    }

    /// A process finishing or changing its children under the same shell
    /// command does not invalidate consent. A different command, added draft,
    /// or a new active surface does.
    public func isCovered(by previous: SessionCloseState) -> Bool {
        guard requiresConfirmation else { return true }
        guard !hasDraftInput || previous.hasDraftInput,
              !hasActiveSurface || previous.hasActiveSurface,
              !isAlternateScreen || previous.isAlternateScreen,
              !processStateUnknown || previous.processStateUnknown else { return false }
        if let runningCommand {
            return runningCommand == previous.runningCommand
        }
        return Set(runningProcesses).isSubset(of: Set(previous.runningProcesses))
    }

    public var workDescription: String? {
        if let runningCommand {
            let command = Self.displayText(runningCommand)
            return command.isEmpty ? "Running command" : command
        }
        if !runningProcesses.isEmpty {
            return runningProcesses.prefix(3).map(Self.displayText)
                .joined(separator: ", ")
        }
        if isAlternateScreen { return "Full-screen terminal program" }
        if hasActiveSurface { return "Active terminal surface" }
        if hasDraftInput { return "Unsubmitted terminal input" }
        if processStateUnknown { return "Terminal process could not be checked" }
        return nil
    }

    private static func displayText(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        })).trimmingCharacters(in: .whitespacesAndNewlines).prefix(120).description
    }
}

public enum SessionClosePolicy {
    public struct Assessment: Equatable, Sendable {
        public let affectedPanes: [SessionCloseState]
        public let dirtyDocumentCount: Int

        public var requiresTerminalConfirmation: Bool { !affectedPanes.isEmpty }

        /// A bounded list for one pane, a window, or the whole application.
        public var explanation: String {
            var lines = affectedPanes.prefix(5).compactMap(\.workDescription)
            if affectedPanes.count > 5 {
                lines.append("and \(affectedPanes.count - 5) more terminal panes")
            }
            var text = "Closing will stop running terminal processes and discard any unsubmitted input."
            if !lines.isEmpty { text += "\n\n" + lines.map { "• " + $0 }.joined(separator: "\n") }
            if dirtyDocumentCount > 0 {
                text += "\n\n\(dirtyDocumentCount) unsaved document\(dirtyDocumentCount == 1 ? "" : "s") will also need a save or discard decision."
            }
            return text
        }
    }

    public static func assess(
        _ states: [SessionCloseState], dirtyDocumentCount: Int = 0
    ) -> Assessment {
        Assessment(
            affectedPanes: states.filter(\.requiresConfirmation),
            dirtyDocumentCount: max(0, dirtyDocumentCount))
    }
}

/// A bounded, in-process libproc query. Looking at the shell's children also
/// protects background jobs and shells without OSC 133 integration, without
/// starting a `ps` subprocess on the UI thread.
public enum SessionProcessInspector {
    public struct Snapshot: Equatable, Sendable {
        public let runningPrograms: [String]
        public let isUnknown: Bool
    }

    public static func inspect(shellPID: Int32) -> Snapshot {
        guard shellPID > 0 else {
            return Snapshot(runningPrograms: [], isUnknown: false)
        }
        guard let shell = processInfo(shellPID) else {
            // An exited shell is harmless. A live but unreadable one is not
            // enough evidence to silently close potentially running work.
            let exists = Darwin.kill(shellPID, 0) == 0 || errno == EPERM
            return Snapshot(runningPrograms: [], isUnknown: exists)
        }
        if shell.pbi_status == UInt32(SZOMB) {
            return Snapshot(runningPrograms: [], isUnknown: false)
        }

        var children = [pid_t](repeating: 0, count: 1024)
        errno = 0
        let count = children.withUnsafeMutableBytes { buffer in
            proc_listchildpids(shellPID, buffer.baseAddress, Int32(buffer.count))
        }
        var unknown = count < 0 || (count == 0 && errno != 0)
        if count >= children.count { unknown = true }
        var names: [String] = []
        for pid in children.prefix(max(0, min(Int(count), children.count))) where pid > 0 {
            guard let info = processInfo(pid) else {
                if Darwin.kill(pid, 0) == 0 { unknown = true }
                continue
            }
            guard info.pbi_ppid == UInt32(shellPID),
                  info.pbi_status != UInt32(SZOMB) else { continue }
            let name = processName(info)
            if !names.contains(name) { names.append(name) }
        }

        let shellName = processName(shell)
        let shells: Set<String> = [
            "sh", "bash", "zsh", "fish", "tcsh", "csh", "dash", "ksh",
            "nu", "xonsh", "pwsh", "elvish",
        ]
        // `exec vim` replaces the original shell PID; there need not be a
        // child process left for the query above to find.
        // Darwin keeps BSD pbi_status == SRUN for an ordinary shell even
        // while all of its threads sleep waiting for prompt input. It is not
        // evidence of an executing command; OSC markers supply that signal.
        if !shells.contains(shellName) || shell.pbi_status == UInt32(SSTOP) {
            if !names.contains(shellName) { names.insert(shellName, at: 0) }
        }
        return Snapshot(runningPrograms: names, isUnknown: unknown)
    }

    private static func processInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            return nil
        }
        return info
    }

    private static func processName(_ source: proc_bsdinfo) -> String {
        var info = source
        let name = withUnsafeBytes(of: &info.pbi_name) {
            String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
        if !name.isEmpty { return name }
        return withUnsafeBytes(of: &info.pbi_comm) {
            String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

public extension Notification.Name {
    static let cmdySessionStateChanged = Notification.Name("cmdySessionStateChanged")
}
