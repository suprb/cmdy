import Foundation
import CmdyNative

/// Mutable semantic anchors live in the engine and retain their identity when
/// pruning or reset removes them from the tracker.
public final class TerminalBlock {
    let native: OpaquePointer
    private var ownsNative = false
    public let index: Int

    private static let lifetimeCallback: @convention(c) (UnsafeMutableRawPointer?, UInt8) -> Void = { context, event in
        guard let context else { return }
        let reference = Unmanaged<TerminalBlock>.fromOpaque(context)
        let block = reference.takeUnretainedValue()
        if event == 0 { block.ownsNative = true; reference.release() }
        else { _ = reference.retain(); block.ownsNative = false }
    }
    private init(retained native: OpaquePointer) {
        self.native = native
        var info = CmdyZigBlockInfo()
        checkedNative(cmdy_zig_block_info(native, &info))
        index = Int(bitPattern: UInt(info.index))
        let context = Unmanaged.passRetained(self).toOpaque()
        checkedNative(cmdy_zig_block_associate(native, context, Self.lifetimeCallback))
        withExtendedLifetime(self) { cmdy_zig_block_release(native) }
    }
    convenience init(index: Int, promptRow: Int, timestamp: Double) {
        guard let native = cmdy_zig_block_create(UInt64(bitPattern: Int64(index)), promptRow, timestamp) else {
            preconditionFailure("Cannot allocate CMDY native block")
        }
        self.init(retained: native)
    }
    static func wrapping(retained native: OpaquePointer) -> TerminalBlock {
        if let context = cmdy_zig_block_swift_context(native) {
            let block = Unmanaged<TerminalBlock>.fromOpaque(context).takeUnretainedValue()
            withExtendedLifetime(block) { cmdy_zig_block_release(native) }
            return block
        }
        return TerminalBlock(retained: native)
    }
    deinit {
        precondition(ownsNative)
        checkedNative(cmdy_zig_block_disassociate(native, Unmanaged.passUnretained(self).toOpaque()))
        cmdy_zig_block_release(native)
    }
    private var info: CmdyZigBlockInfo {
        get { var result = CmdyZigBlockInfo(); checkedNative(cmdy_zig_block_info(native, &result)); return result }
        set { var value = newValue; checkedNative(cmdy_zig_block_set_info(native, &value)) }
    }
    public internal(set) var promptRow: Int {
        get { info.prompt_row }
        set { var value = info; value.prompt_row = newValue; info = value }
    }
    public internal(set) var inputStart: (row: Int, col: Int)? {
        get { let value = info; return value.has_input == 0 ? nil : (value.input_row, value.input_col) }
        set { var value = info; value.has_input = newValue == nil ? 0 : 1
            value.input_row = newValue?.row ?? 0; value.input_col = newValue?.col ?? 0; info = value }
    }
    public internal(set) var commandRow: Int {
        get { info.command_row }
        set { var value = info; value.command_row = newValue; info = value }
    }
    public internal(set) var endRow: Int? {
        get { let value = info; return value.has_end == 0 ? nil : value.end_row }
        set { var value = info; value.end_row = newValue ?? 0; value.has_end = newValue == nil ? 0 : 1; info = value }
    }
    public internal(set) var exitCode: Int? {
        get { let value = info; return value.has_exit == 0 ? nil : value.exit_code }
        set { var value = info; value.exit_code = newValue ?? 0; value.has_exit = newValue == nil ? 0 : 1; info = value }
    }
    public internal(set) var running: Bool {
        get { info.running != 0 }
        set { var value = info; value.running = newValue ? 1 : 0; info = value }
    }
    public internal(set) var startedAt: Double {
        get { info.started_at }
        set { var value = info; value.started_at = newValue; info = value }
    }
    public internal(set) var finishedAt: Double? {
        get { let value = info; return value.has_finished == 0 ? nil : value.finished_at }
        set { var value = info; value.finished_at = newValue ?? 0; value.has_finished = newValue == nil ? 0 : 1; info = value }
    }
}

public final class BlockTracker {
    let native: OpaquePointer
    private let owner: NativeEngineOwner?
    private var changeCallback: (() -> Void)?
    public var onChange: (() -> Void)? {
        get { changeCallback }
        set {
            // Captured objects may reenter the engine when the old closure dies.
            // Publish the callback and native subscription before that release.
            let previous = changeCallback
            withExtendedLifetime(previous) {
                changeCallback = newValue
                if let owner {
                    checkedNative(cmdy_zig_terminal_set_block_change_events(
                        owner.handle, newValue == nil ? 0 : 1))
                }
            }
        }
    }
    public var onCommandFinished: ((TerminalBlock) -> Void)?

    init() {
        guard let native = cmdy_zig_blocks_create() else { preconditionFailure("Cannot allocate CMDY block tracker") }
        self.native = native; owner = nil
    }
    init(native: OpaquePointer, owner: NativeEngineOwner) {
        self.native = native; self.owner = owner
        checkedNative(cmdy_zig_terminal_set_block_change_events(owner.handle, 0))
    }
    deinit { if owner == nil { cmdy_zig_blocks_free(native) } }

    public var blocks: [TerminalBlock] {
        (0..<cmdy_zig_blocks_count(native)).compactMap {
            cmdy_zig_blocks_at(native, $0).map { TerminalBlock.wrapping(retained: $0) }
        }
    }
    public var promptRows: [Int] { blocks.map(\.promptRow) }
    public var isRunning: Bool { cmdy_zig_blocks_running(native) != 0 }
    public var lastCompletedBlock: TerminalBlock? {
        cmdy_zig_blocks_last_completed(native).map { TerminalBlock.wrapping(retained: $0) }
    }
    func publishNativeChange() { onChange?() }
    /// The synchronous terminal event borrows this block; wrapping takes its
    /// own reference before a callback can reset the tracker.
    func publishNativeCommandFinished(native: OpaquePointer) {
        guard let retained = cmdy_zig_block_retain(native) else { return }
        let block = TerminalBlock.wrapping(retained: retained)
        onCommandFinished?(block)
    }
    func promptStarted(row: Int, timestamp: Double) {
        checkedNative(cmdy_zig_blocks_prompt_started(native, row, timestamp)); onChange?()
    }
    func promptEnded(row: Int, col: Int) { cmdy_zig_blocks_prompt_ended(native, row, col); onChange?() }
    func commandStarted(row: Int) { if cmdy_zig_blocks_command_started(native, row) != 0 { onChange?() } }
    @discardableResult
    func commandFinished(row: Int, exitCode: Int?, timestamp: Double) -> TerminalBlock? {
        guard let retained = cmdy_zig_blocks_command_finished(native, row, exitCode ?? 0, exitCode == nil ? 0 : 1, timestamp) else { return nil }
        let block = TerminalBlock.wrapping(retained: retained)
        onChange?(); onCommandFinished?(block); return block
    }
    func rebase(droppedLines dropped: Int) {
        guard dropped > 0 else { return }
        cmdy_zig_blocks_rebase(native, dropped); onChange?()
    }
    func remapRows(_ map: (Int) -> Int) {
        withoutActuallyEscaping(map) { closure in
            var closure = closure
            withUnsafeMutablePointer(to: &closure) { context in
                checkedNative(cmdy_zig_blocks_remap(native, context) { context, row in
                    context!.assumingMemoryBound(to: ((Int) -> Int).self).pointee(row)
                })
            }
        }
        onChange?()
    }
    func handleScrollbackCleared() { reset() }
    public func reset() { cmdy_zig_blocks_reset(native); onChange?() }
}
