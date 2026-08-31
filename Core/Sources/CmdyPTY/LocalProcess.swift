import CmdyPTYShim
import Darwin
import Dispatch
import Foundation

public protocol LocalProcessDelegate: AnyObject {
    func processTerminated(_ source: LocalProcess, exitCode: Int32?)
    func dataReceived(slice: ArraySlice<UInt8>)
    func getWindowSize() -> winsize
}

private final class PTYSession: @unchecked Sendable {
    struct ReapState {
        let complete: Bool
        let waitStatus: Int32?
    }

    let generation: UInt64
    let pid: pid_t
    let masterDescriptor: Int32

    // Accessed only on LocalProcess.ioQueue.
    var descriptorIsOpen = true
    var reachedEOF = false
    var readIsSuspended = false
    var terminationStarted = false
    var readSource: DispatchSourceRead?
    var writeSource: DispatchSourceWrite?
    var pendingWrites: [PendingWrite] = []
    var pendingWriteIndex = 0

    private let markerLock = NSLock()
    private var acceptsData = true
    private var reportsTermination = true
    private var reaped = false
    private var waitStatus: Int32?

    init(generation: UInt64, pid: pid_t, masterDescriptor: Int32) {
        self.generation = generation
        self.pid = pid
        self.masterDescriptor = masterDescriptor
    }

    func disableDataDelivery() {
        markerLock.lock()
        acceptsData = false
        markerLock.unlock()
    }

    func shouldDeliverData() -> Bool {
        markerLock.lock()
        defer { markerLock.unlock() }
        return acceptsData
    }

    func suppressTerminationReport() {
        markerLock.lock()
        reportsTermination = false
        markerLock.unlock()
    }

    func shouldReportTermination() -> Bool {
        markerLock.lock()
        defer { markerLock.unlock() }
        return reportsTermination
    }

    /// Reap and mark the child while holding the same lock used by signaling.
    /// `waitpid` makes the PID reusable, so publishing `reaped` after releasing
    /// this lock would leave a window where escalation could signal a new PID.
    func reapChild() -> Int32? {
        markerLock.lock()
        defer { markerLock.unlock() }

        var status: Int32 = 0
        var result: pid_t
        repeat {
            result = waitpid(pid, &status, 0)
        } while result == -1 && errno == EINTR

        reaped = true
        waitStatus = result == pid ? status : nil
        return waitStatus
    }

    /// The reaped check and signal are one critical section. `reapChild()`
    /// holds this lock across waitpid, closing the PID-reuse race completely.
    func signalProcessGroupIfUnreaped(_ signal: Int32) {
        markerLock.lock()
        defer { markerLock.unlock() }
        guard !reaped, pid > 0 else { return }
        if Darwin.kill(-pid, signal) == -1 && errno == ESRCH {
            _ = Darwin.kill(pid, signal)
        }
    }

    func reapState() -> ReapState {
        markerLock.lock()
        defer { markerLock.unlock() }
        return ReapState(complete: reaped, waitStatus: waitStatus)
    }
}

private struct PendingWrite {
    var bytes: [UInt8]
    var offset = 0
}

/// Best-effort chunk logging isolated from PTY drainage.
private final class HostLogSink: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.cmdy.pty.host-log", qos: .utility)
    private let directoryURL: URL

    init?(directory: String) {
        directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true)
        } catch {
            return nil
        }
    }

    func writeChunk(_ bytes: [UInt8], index: UInt64) {
        guard !bytes.isEmpty else { return }
        queue.async { [directoryURL, bytes] in
            let finalURL = directoryURL.appendingPathComponent("log-\(index)")
            let temporaryURL = directoryURL.appendingPathComponent(
                ".log-\(index).\(UUID().uuidString).tmp")
            let descriptor = temporaryURL.withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path else { return -1 }
                return Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            }
            guard descriptor >= 0 else { return }

            var completed = true
            var offset = 0
            while offset < bytes.count {
                let written = bytes.withUnsafeBytes { buffer -> Int in
                    guard let base = buffer.baseAddress else { return 0 }
                    return Darwin.write(
                        descriptor,
                        base.advanced(by: offset),
                        bytes.count - offset)
                }
                if written > 0 {
                    offset += written
                } else if written == -1 && errno == EINTR {
                    continue
                } else {
                    completed = false
                    break
                }
            }
            Darwin.close(descriptor)
            guard completed else {
                temporaryURL.withUnsafeFileSystemRepresentation { path in
                    if let path { _ = Darwin.unlink(path) }
                }
                return
            }

            temporaryURL.withUnsafeFileSystemRepresentation { source in
                finalURL.withUnsafeFileSystemRepresentation { destination in
                    guard let source, let destination else { return }
                    if Darwin.rename(source, destination) != 0 {
                        _ = Darwin.unlink(source)
                    }
                }
            }
        }
    }
}

/// Reaps children without dedicating one blocked thread to every terminal.
/// Entries outlive LocalProcess so a pane disappearing cannot leave a zombie.
private final class ChildReaper: @unchecked Sendable {
    static let shared = ChildReaper()

    private struct Entry {
        let source: DispatchSourceProcess
        let reap: @Sendable () -> Int32?
        let completion: @Sendable (Int32?) -> Void
    }

    private let queue = DispatchQueue(label: "com.cmdy.pty.reaper", qos: .utility)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private var entries: [pid_t: Entry] = [:]

    private init() {
        queue.setSpecific(key: queueKey, value: 1)
    }

    func register(
        pid: pid_t,
        reap: @escaping @Sendable () -> Int32?,
        completion: @escaping @Sendable (Int32?) -> Void
    ) {
        syncOnQueue {
            precondition(entries[pid] == nil, "a child PID may only have one reaper")
            let source = DispatchSource.makeProcessSource(
                identifier: pid,
                eventMask: .exit,
                queue: queue)
            let entry = Entry(source: source, reap: reap, completion: completion)
            entries[pid] = entry
            source.setEventHandler { [weak self] in
                self?.reap(pid: pid)
            }
            source.resume()
        }
    }

    private func reap(pid: pid_t) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let entry = entries.removeValue(forKey: pid) else { return }

        let waitStatus = entry.reap()
        entry.source.setEventHandler {}
        entry.source.cancel()
        entry.completion(waitStatus)
    }

    private func syncOnQueue<T>(_ operation: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return operation()
        }
        return queue.sync(execute: operation)
    }
}

/// A reusable, queue-driven local process attached to a native pseudo-terminal.
///
/// The child is a session/process-group leader. Reads and writes are
/// nonblocking; at most one read chunk waits for the delegate, so a stalled UI
/// applies kernel PTY backpressure instead of accumulating unbounded memory.
public final class LocalProcess: @unchecked Sendable {
    private static let readChunkSize = 64 * 1024
    private static let hangupDelay: DispatchTimeInterval = .milliseconds(200)
    private static let killDelay: DispatchTimeInterval = .milliseconds(750)

    private weak var delegate: LocalProcessDelegate?
    private let callbackQueue: DispatchQueue
    private let ioQueue: DispatchQueue
    private let ioQueueKey = DispatchSpecificKey<UInt8>()
    private let generationLock = NSLock()

    // Accessed only on ioQueue unless guarded by generationLock.
    private var activeSession: PTYSession?
    private var nextGeneration: UInt64 = 0
    private var latestCallbackGeneration: UInt64 = 0
    private var hostLogSink: HostLogSink?
    private var hostLogCounter: UInt64 = 0

    public init(
        delegate: LocalProcessDelegate,
        dispatchQueue: DispatchQueue? = nil
    ) {
        self.delegate = delegate
        callbackQueue = dispatchQueue ?? .main
        ioQueue = DispatchQueue(
            label: "com.cmdy.pty.io.\(UUID().uuidString)",
            qos: .userInteractive)
        ioQueue.setSpecific(key: ioQueueKey, value: 1)
    }

    deinit {
        syncOnIOQueue {
            hostLogSink = nil
            guard let session = activeSession else { return }
            activeSession = nil
            retire(session, reportTermination: false)
        }
    }

    public var running: Bool {
        syncOnIOQueue {
            guard let session = activeSession else { return false }
            return !session.reapState().complete
        }
    }

    public var shellPid: pid_t {
        syncOnIOQueue {
            guard let session = activeSession,
                  !session.reapState().complete else { return 0 }
            return session.pid
        }
    }

    public var childfd: Int32 {
        syncOnIOQueue {
            guard let session = activeSession, session.descriptorIsOpen else { return -1 }
            return session.masterDescriptor
        }
    }

    public func startProcess(
        executable: String = "/bin/bash",
        args: [String] = [],
        environment: [String]? = nil,
        execName: String? = nil,
        currentDirectory: String? = nil
    ) {
        // Keep delegate work outside ioQueue (TerminalModel's delegate may
        // synchronise with its own queue), while making the common no-op path
        // fully inert and re-checking against concurrent starters.
        guard syncOnIOQueue({ activeSession == nil }) else { return }
        let initialSize = delegate?.getWindowSize() ?? winsize()
        syncOnIOQueue {
            guard activeSession == nil else { return }
            startOnIOQueue(
                executable: executable,
                args: args,
                environment: environment,
                execName: execName,
                currentDirectory: currentDirectory,
                initialSize: initialSize)
        }
    }

    public func send(data: ArraySlice<UInt8>) {
        guard !data.isEmpty else { return }
        let bytes = Array(data)
        asyncOnIOQueue { [weak self] in
            guard let self,
                  let session = activeSession,
                  session.descriptorIsOpen,
                  !session.reapState().complete else { return }
            session.pendingWrites.append(PendingWrite(bytes: bytes))
            flushWrites(for: session)
        }
    }

    public func terminate() {
        syncOnIOQueue {
            guard let session = activeSession else { return }
            // Retirement is synchronous: callers may immediately launch a new
            // generation while this child is reaped in the background.
            activeSession = nil
            retire(session, reportTermination: false)
        }
    }

    public static func defaultEnvironment(termName: String) -> [String] {
        let host = ProcessInfo.processInfo.environment
        var environment = [
            "TERM=\(termName)",
            "COLORTERM=truecolor",
            "LANG=en_US.UTF-8",
        ]
        for name in ["LOGNAME", "USER", "DISPLAY", "LC_TYPE", "USERNAME", "HOME", "PATH"] {
            if let value = host[name] {
                environment.append("\(name)=\(value)")
            }
        }
        return environment
    }

    public func setHostLogging(directory: String?) {
        syncOnIOQueue {
            hostLogSink = directory.flatMap(HostLogSink.init(directory:))
        }
    }

    private func startOnIOQueue(
        executable: String,
        args: [String],
        environment: [String]?,
        execName: String?,
        currentDirectory: String?,
        initialSize: winsize
    ) {
        dispatchPrecondition(condition: .onQueue(ioQueue))

        // Compatibility: start is not an implicit replace operation.
        guard activeSession == nil else { return }

        nextGeneration &+= 1
        let generation = nextGeneration
        setLatestCallbackGeneration(generation)

        var pid: pid_t = 0
        var masterDescriptor: Int32 = -1
        let spawnError = Self.spawnPTY(
            executable: executable,
            args: args,
            environment: environment ?? Self.defaultEnvironment(termName: "xterm-256color"),
            execName: execName,
            currentDirectory: currentDirectory,
            initialSize: initialSize,
            pid: &pid,
            masterDescriptor: &masterDescriptor)

        guard spawnError == 0, pid > 0, masterDescriptor >= 0 else {
            if masterDescriptor >= 0 { Darwin.close(masterDescriptor) }
            reportStartFailure(generation: generation)
            return
        }

        guard Self.configureMasterDescriptor(masterDescriptor) else {
            Darwin.close(masterDescriptor)
            Self.signalProcessGroup(pid: pid, signal: SIGKILL)
            let failedPID = pid
            ChildReaper.shared.register(
                pid: failedPID,
                reap: { Self.waitForChild(pid: failedPID) },
                completion: { [weak self] _ in
                    self?.reportStartFailure(generation: generation)
                })
            return
        }

        let session = PTYSession(
            generation: generation,
            pid: pid,
            masterDescriptor: masterDescriptor)
        activeSession = session

        ChildReaper.shared.register(
            pid: pid,
            reap: { [session] in session.reapChild() },
            completion: { [weak self, session] _ in
                self?.ioQueue.async { [weak self, session] in
                    self?.childWasReaped(session)
                }
            })

        let source = DispatchSource.makeReadSource(
            fileDescriptor: masterDescriptor,
            queue: ioQueue)
        session.readSource = source
        source.setEventHandler { [weak self, session] in
            self?.readAvailableData(for: session)
        }
        source.resume()
    }

    private func readAvailableData(for session: PTYSession) {
        dispatchPrecondition(condition: .onQueue(ioQueue))
        guard activeSession === session, session.descriptorIsOpen else { return }

        var storage = [UInt8](repeating: 0, count: Self.readChunkSize)
        var count: Int
        repeat {
            count = storage.withUnsafeMutableBytes { buffer -> Int in
                guard let baseAddress = buffer.baseAddress else { return 0 }
                return Darwin.read(session.masterDescriptor, baseAddress, buffer.count)
            }
        } while count == -1 && errno == EINTR

        if count > 0 {
            storage.removeSubrange(count..<storage.count)
            if let hostLogSink {
                let index = hostLogCounter
                hostLogCounter &+= 1
                hostLogSink.writeChunk(storage, index: index)
            }
            guard let source = session.readSource else { return }
            source.suspend()
            session.readIsSuspended = true

            callbackQueue.async { [weak self, session, storage] in
                if session.shouldDeliverData() {
                    self?.delegate?.dataReceived(slice: storage[...])
                }
                self?.ioQueue.async { [weak self, session] in
                    self?.resumeReading(session)
                }
            }
            return
        }

        if count == -1 && (errno == EAGAIN || errno == EWOULDBLOCK) {
            return
        }

        // A closed PTY commonly reports EIO on Darwin rather than zero.
        session.reachedEOF = true
        closeMaster(for: session)
        finishIfReady(session)
    }

    private func resumeReading(_ session: PTYSession) {
        dispatchPrecondition(condition: .onQueue(ioQueue))
        guard activeSession === session,
              session.descriptorIsOpen,
              session.readIsSuspended,
              let source = session.readSource else { return }
        session.readIsSuspended = false
        source.resume()
    }

    private func flushWrites(for session: PTYSession) {
        dispatchPrecondition(condition: .onQueue(ioQueue))
        guard activeSession === session, session.descriptorIsOpen else {
            session.pendingWrites.removeAll(keepingCapacity: false)
            cancelWriteSource(for: session)
            return
        }

        while session.pendingWriteIndex < session.pendingWrites.count {
            var pending = session.pendingWrites[session.pendingWriteIndex]
            let written = pending.bytes.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return Darwin.write(
                    session.masterDescriptor,
                    base.advanced(by: pending.offset),
                    pending.bytes.count - pending.offset)
            }

            if written > 0 {
                pending.offset += written
                if pending.offset == pending.bytes.count {
                    session.pendingWriteIndex += 1
                } else {
                    session.pendingWrites[session.pendingWriteIndex] = pending
                }
                continue
            }
            if written == -1 && errno == EINTR { continue }
            if written == -1 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                ensureWriteSource(for: session)
                return
            }

            session.pendingWrites.removeAll(keepingCapacity: false)
            session.pendingWriteIndex = 0
            cancelWriteSource(for: session)
            return
        }

        session.pendingWrites.removeAll(keepingCapacity: true)
        session.pendingWriteIndex = 0
        cancelWriteSource(for: session)
    }

    private func ensureWriteSource(for session: PTYSession) {
        guard session.writeSource == nil, session.descriptorIsOpen else { return }
        let source = DispatchSource.makeWriteSource(
            fileDescriptor: session.masterDescriptor,
            queue: ioQueue)
        session.writeSource = source
        source.setEventHandler { [weak self, session] in
            self?.flushWrites(for: session)
        }
        source.resume()
    }

    private func cancelWriteSource(for session: PTYSession) {
        guard let source = session.writeSource else { return }
        source.setEventHandler {}
        source.cancel()
        session.writeSource = nil
    }

    private func childWasReaped(_ session: PTYSession) {
        dispatchPrecondition(condition: .onQueue(ioQueue))
        guard activeSession === session else { return }
        finishIfReady(session)
    }

    private func finishIfReady(_ session: PTYSession) {
        dispatchPrecondition(condition: .onQueue(ioQueue))
        let reapState = session.reapState()
        guard activeSession === session, session.reachedEOF, reapState.complete else { return }

        activeSession = nil
        session.disableDataDelivery()
        closeMaster(for: session)

        guard session.shouldReportTermination() else { return }
        let exitCode = Self.decodeExitCode(waitStatus: reapState.waitStatus)
        callbackQueue.async { [weak self, session] in
            guard let self,
                  session.shouldReportTermination(),
                  self.isLatestCallbackGeneration(session.generation) else { return }
            self.delegate?.processTerminated(self, exitCode: exitCode)
        }
    }

    private func retire(_ session: PTYSession, reportTermination: Bool) {
        dispatchPrecondition(condition: .onQueue(ioQueue))
        if !reportTermination { session.suppressTerminationReport() }
        session.disableDataDelivery()
        session.reachedEOF = true
        closeMaster(for: session)
        beginTermination(of: session)
    }

    private func closeMaster(for session: PTYSession) {
        dispatchPrecondition(condition: .onQueue(ioQueue))
        guard session.descriptorIsOpen else { return }
        session.descriptorIsOpen = false

        if let source = session.readSource {
            source.setEventHandler {}
            if session.readIsSuspended {
                session.readIsSuspended = false
                source.resume()
            }
            source.cancel()
            session.readSource = nil
        }
        cancelWriteSource(for: session)
        session.pendingWrites.removeAll(keepingCapacity: false)
        session.pendingWriteIndex = 0
        Darwin.close(session.masterDescriptor)
    }

    private func beginTermination(of session: PTYSession) {
        dispatchPrecondition(condition: .onQueue(ioQueue))
        guard !session.terminationStarted else { return }
        session.terminationStarted = true

        Self.signalIfUnreaped(session, signal: SIGTERM)
        ioQueue.asyncAfter(deadline: .now() + Self.hangupDelay) { [session] in
            Self.signalIfUnreaped(session, signal: SIGHUP)
        }
        ioQueue.asyncAfter(deadline: .now() + Self.killDelay) { [session] in
            Self.signalIfUnreaped(session, signal: SIGKILL)
        }
    }

    private func reportStartFailure(generation: UInt64) {
        callbackQueue.async { [weak self] in
            guard let self, self.isLatestCallbackGeneration(generation) else { return }
            self.delegate?.processTerminated(self, exitCode: nil)
        }
    }

    private func setLatestCallbackGeneration(_ generation: UInt64) {
        generationLock.lock()
        latestCallbackGeneration = generation
        generationLock.unlock()
    }

    private func isLatestCallbackGeneration(_ generation: UInt64) -> Bool {
        generationLock.lock()
        defer { generationLock.unlock() }
        return latestCallbackGeneration == generation
    }

    private func syncOnIOQueue<T>(_ operation: () -> T) -> T {
        if DispatchQueue.getSpecific(key: ioQueueKey) != nil {
            return operation()
        }
        return ioQueue.sync(execute: operation)
    }

    private func asyncOnIOQueue(_ operation: @escaping @Sendable () -> Void) {
        if DispatchQueue.getSpecific(key: ioQueueKey) != nil {
            operation()
        } else {
            ioQueue.async(execute: operation)
        }
    }

    private static func configureMasterDescriptor(_ descriptor: Int32) -> Bool {
        let descriptorFlags = fcntl(descriptor, F_GETFD)
        guard descriptorFlags >= 0,
              fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0 else {
            return false
        }

        let statusFlags = fcntl(descriptor, F_GETFL)
        guard statusFlags >= 0,
              fcntl(descriptor, F_SETFL, statusFlags | O_NONBLOCK) == 0 else {
            return false
        }
        return true
    }

    private static func signalIfUnreaped(_ session: PTYSession, signal: Int32) {
        session.signalProcessGroupIfUnreaped(signal)
    }

    private static func waitForChild(pid: pid_t) -> Int32? {
        var status: Int32 = 0
        var result: pid_t
        repeat {
            result = waitpid(pid, &status, 0)
        } while result == -1 && errno == EINTR
        return result == pid ? status : nil
    }

    private static func signalProcessGroup(pid: pid_t, signal: Int32) {
        guard pid > 0 else { return }
        if Darwin.kill(-pid, signal) == -1 && errno == ESRCH {
            _ = Darwin.kill(pid, signal)
        }
    }

    private static func decodeExitCode(waitStatus: Int32?) -> Int32? {
        guard let waitStatus else { return nil }
        let terminatingSignal = waitStatus & 0x7f
        if terminatingSignal == 0 {
            return (waitStatus >> 8) & 0xff
        }
        guard terminatingSignal != 0x7f else { return nil }
        return 128 + terminatingSignal
    }

    private static func spawnPTY(
        executable: String,
        args: [String],
        environment: [String]?,
        execName: String?,
        currentDirectory: String?,
        initialSize: winsize,
        pid: inout pid_t,
        masterDescriptor: inout Int32
    ) -> Int32 {
        let argumentStrings = [execName ?? executable] + args
        let descriptorLimit = max(Int32(STDERR_FILENO + 1), getdtablesize())
        var size = initialSize

        return withCStringVector(argumentStrings) { argv in
            withOptionalCStringVector(environment) { envp in
                executable.withCString { executablePointer in
                    withOptionalCString(currentDirectory) { directoryPointer in
                        cmdy_spawn_pty(
                            &pid,
                            &masterDescriptor,
                            executablePointer,
                            argv,
                            envp,
                            directoryPointer,
                            &size,
                            descriptorLimit)
                    }
                }
            }
        }
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

    private static func withOptionalCStringVector<Result>(
        _ strings: [String]?,
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Result
    ) -> Result {
        guard let strings else { return body(nil) }
        return withCStringVector(strings, body)
    }

    private static func withOptionalCString<Result>(
        _ string: String?,
        _ body: (UnsafePointer<CChar>?) -> Result
    ) -> Result {
        guard let string else { return body(nil) }
        return string.withCString(body)
    }
}
