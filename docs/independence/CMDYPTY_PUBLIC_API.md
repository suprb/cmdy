# CmdyPTY frozen public API manifest

Status: implementation-free compatibility manifest

Baseline module: `CmdyPTY` compiled before replacement at repository ref `584624985809f6000a82d3b3b97e43ef885af572`

Machine-readable authority: `docs/independence/baselines/CmdyPTY.symbols.json`

This file contains declarations only. It does not describe the former process, queue, buffering, fork, exec, signal, or descriptor implementation.

```swift
public protocol LocalProcessDelegate: AnyObject {
    func processTerminated(_ source: LocalProcess, exitCode: Int32?)
    func dataReceived(slice: ArraySlice<UInt8>)
    func getWindowSize() -> winsize
}

public final class LocalProcess: @unchecked Sendable {
    public private(set) var childfd: Int32
    public private(set) var shellPid: pid_t
    public private(set) var running: Bool

    public init(
        delegate: LocalProcessDelegate,
        dispatchQueue: DispatchQueue? = nil
    )

    public func send(data: ArraySlice<UInt8>)
    public func startProcess(
        executable: String = "/bin/bash",
        args: [String] = [],
        environment: [String]? = nil,
        execName: String? = nil,
        currentDirectory: String? = nil
    )
    public static func defaultEnvironment(termName: String) -> [String]
    public func terminate()
    public func setHostLogging(directory: String?)
}

public class PseudoTerminalHelpers {
    public static func fork(
        andExec: String,
        args: [String],
        env: [String],
        currentDirectory: String? = nil,
        desiredWindowSize: inout winsize
    ) -> (pid: pid_t, masterFd: Int32)?

    public static func setWinSize(
        masterPtyDescriptor: Int32,
        windowSize: inout winsize
    ) -> Int32

    public static func availableBytes(
        fd: Int32
    ) -> (status: Int32, size: Int32)
}
```

The nullable `dispatchQueue` and all defaults are compatibility-significant. The exact lifecycle and helper edge behavior are specified in `CMDYPTY_CONTRACT.md`.

Use `scripts/check-independent-api.sh` against the frozen public symbol graph
for declaration details not represented by this human-readable list. The old
private ABI layout remains archived for provenance only.
