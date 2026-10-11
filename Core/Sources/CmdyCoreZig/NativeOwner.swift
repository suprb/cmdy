import CmdyNative

@inline(__always)
func checkedNative(_ result: Int32, file: StaticString = #fileID, line: UInt = #line) {
    precondition(result == 0, "CMDY native engine failed with status \(result)", file: file, line: line)
}

/// Buffers and the public parser can outlive their terminal facade. They retain
/// this owner without retaining the facade or its host callbacks.
final class NativeEngineOwner {
    let handle: OpaquePointer

    init(cols: Int, rows: Int, scrollback: Int) {
        guard let handle = cmdy_zig_terminal_create(cols, rows, scrollback) else {
            preconditionFailure("Cannot allocate CMDY native terminal")
        }
        self.handle = handle
    }

    deinit { cmdy_zig_terminal_free(handle) }
}
