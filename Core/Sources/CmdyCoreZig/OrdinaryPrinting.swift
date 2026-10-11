import CmdyNative

private final class UnicodeContinuation {
    let source: VTParser
    let terminal: CmdyTerminal
    let requiresDelegateIdentity: Bool
    init(_ source: VTParser, _ terminal: CmdyTerminal, _ requiresDelegateIdentity: Bool) {
        self.source = source
        self.terminal = terminal
        self.requiresDelegateIdentity = requiresDelegateIdentity
    }
    static let callback: @convention(c) (UnsafeMutableRawPointer?) -> UInt8 = { context in
        guard let context else { return 0 }
        let check = Unmanaged<UnicodeContinuation>.fromOpaque(context).takeUnretainedValue()
        return check.source.canContinueOrdinaryUnicodeBatch(for: check.terminal,
            requiresDelegateIdentity: check.requiresDelegateIdentity) ? 1 : 0
    }
}

extension CmdyTerminal {
    func parserPrintOrdinaryUnicode(_ bytes: ArraySlice<UInt8>, first: UnicodeScalar,
        firstByteCount: Int, sourceParser: VTParser? = nil,
        requiresDelegateIdentity: Bool = false) -> Int
    {
        let check = sourceParser.map { UnicodeContinuation($0, self, requiresDelegateIdentity) }
        var consumed = 0
        withExtendedLifetime((self, check)) {
            bytes.withUnsafeBufferPointer { input in
                checkedNative(cmdy_zig_terminal_print_ordinary_unicode(nativeOwner.handle,
                    input.baseAddress, input.count, first.value, firstByteCount,
                    check.map { Unmanaged.passUnretained($0).toOpaque() },
                    check == nil ? nil : UnicodeContinuation.callback, &consumed))
            }
        }
        return consumed
    }
}
