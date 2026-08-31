import CmdyPTYShim
import Darwin

/// Operations that apply to the master side of a pseudo-terminal.
public class PseudoTerminalHelpers {
    /// Forks a PTY child and executes the supplied path. `args` is the complete
    /// argv vector; this compatibility helper intentionally does not add an
    /// argv-zero entry.
    public static func fork(
        andExec: String,
        args: [String],
        env: [String],
        currentDirectory: String? = nil,
        desiredWindowSize: inout winsize
    ) -> (pid: pid_t, masterFd: Int32)? {
        let executable = andExec
        var pid: pid_t = 0
        var masterDescriptor: Int32 = -1
        let descriptorLimit = max(Int32(STDERR_FILENO + 1), getdtablesize())

        let status = withCStringVector(args) { argv in
            withCStringVector(env) { envp in
                executable.withCString { executablePointer in
                    withOptionalCString(currentDirectory) { directoryPointer in
                        cmdy_spawn_pty(
                            &pid,
                            &masterDescriptor,
                            executablePointer,
                            argv,
                            envp,
                            directoryPointer,
                            &desiredWindowSize,
                            descriptorLimit)
                    }
                }
            }
        }

        guard status == 0, pid > 0, masterDescriptor >= 0 else {
            if masterDescriptor >= 0 { Darwin.close(masterDescriptor) }
            return nil
        }

        return (pid: pid, masterFd: masterDescriptor)
    }

    /// Updates the terminal dimensions. The kernel delivers `SIGWINCH` to the
    /// foreground process group when the dimensions actually change.
    public static func setWinSize(
        masterPtyDescriptor: Int32,
        windowSize: inout winsize
    ) -> Int32 {
        guard masterPtyDescriptor >= 0 else {
            errno = EBADF
            return -1
        }
        return ioctl(masterPtyDescriptor, TIOCSWINSZ, &windowSize)
    }

    /// Returns the kernel's current readable-byte estimate for a descriptor.
    public static func availableBytes(fd: Int32) -> (status: Int32, size: Int32) {
        var size: Int32 = 0
        let status = cmdy_pty_available_bytes(fd, &size)
        return (status: status, size: size)
    }

    private static func withCStringVector<Result>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
    ) -> Result {
        var pointers = strings.map { strdup($0) }
        pointers.append(nil)
        defer {
            for pointer in pointers where pointer != nil { free(pointer) }
        }
        return pointers.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress!)
        }
    }

    private static func withOptionalCString<Result>(
        _ string: String?,
        _ body: (UnsafePointer<CChar>?) -> Result
    ) -> Result {
        guard let string else { return body(nil) }
        return string.withCString(body)
    }
}
