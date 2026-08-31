import Foundation
import CmdyKit
import Darwin

/// Captures a stack trace on crash to /tmp/cmdy-crash.log. Uses only
/// async-signal-safe calls (open/backtrace_symbols_fd) in the signal handler.
enum CrashLogger {
    static func install() {
        // ObjC/AppKit exceptions (common for AppKit crashes) — richest info.
        NSSetUncaughtExceptionHandler { ex in
            let text = "UNCAUGHT EXCEPTION: \(ex.name.rawValue): \(ex.reason ?? "")\n\n"
                + ex.callStackSymbols.joined(separator: "\n")
            try? text.write(toFile: "/tmp/cmdy-crash.log", atomically: true, encoding: .utf8)
        }
        // Fatal signals (Swift traps, EXC_BAD_ACCESS) — signal-safe native backtrace.
        for sig in [SIGSEGV, SIGABRT, SIGILL, SIGBUS, SIGTRAP, SIGFPE] {
            signal(sig) { s in
                let fd = open("/tmp/cmdy-crash.log", O_WRONLY | O_CREAT | O_TRUNC, 0o644)
                if fd >= 0 {
                    var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 128)
                    let n = backtrace(&frames, 128)
                    backtrace_symbols_fd(&frames, n, fd)
                    close(fd)
                }
                signal(s, SIG_DFL)
                raise(s)
            }
        }
    }
}
