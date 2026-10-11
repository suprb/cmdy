import CmdyNative

extension CmdyTerminal {
    @discardableResult
    func handleAPC(_ bytes: ArraySlice<UInt8>) -> Bool {
        var motion: UInt8 = 0
        bytes.withUnsafeBufferPointer {
            checkedNative(cmdy_zig_terminal_handle_apc(UnsafeMutableRawPointer(nativeOwner.handle),
                                                       $0.baseAddress, $0.count, &motion))
        }
        return motion != 0
    }
}
