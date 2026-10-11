import Foundation
import CmdyNative

/// The VT500-series escape sequence parser — Paul Williams' state machine
/// (vt100.net/emu/dec_ansi_parser), byte-driven, with UTF-8 assembled in
/// ground state. The parser knows NOTHING about semantics: it turns bytes
/// into calls on `VTParserDelegate`, and the engine interprets them.
public protocol VTParserDelegate: AnyObject {
    /// A printable grapheme scalar reached ground state.
    func parserPrint(_ scalar: UnicodeScalar)
    /// A contiguous run of printable ASCII reached ground state. Delegates
    /// with a row-oriented backing store can commit this in batches; the
    /// default preserves the scalar callback contract.
    func parserPrintASCII(_ bytes: ArraySlice<UInt8>)
    /// Common shell/text-output unit: printable ASCII immediately followed by
    /// CR LF. A row-oriented delegate can fold the two control transitions and
    /// damage publication into the same batch.
    func parserPrintASCIIAndCRLF(_ bytes: ArraySlice<UInt8>)
    /// Two or more consecutive non-empty printable-ASCII CRLF records, kept as
    /// one slice so a delegate can append populated rows directly.
    func parserPrintASCIILines(_ bytes: ArraySlice<UInt8>)
    /// A C0/C1 control was executed (BEL, BS, HT, LF, CR, SO, SI …).
    func parserExecute(_ byte: UInt8)
    /// CSI dispatch: final byte + params + intermediates (+ private marker).
    func parserCSI(final: UInt8, params: [Int], collect: [UInt8])
    /// ESC dispatch: final byte + intermediates.
    func parserESC(final: UInt8, collect: [UInt8])
    /// OSC dispatch: numeric code + payload bytes after the first ';'.
    func parserOSC(code: Int, payload: ArraySlice<UInt8>)
    /// DCS: hook (start), put (payload bytes), unhook (end).
    func parserDCSHook(final: UInt8, params: [Int], collect: [UInt8])
    func parserDCSPut(_ bytes: ArraySlice<UInt8>)
    func parserDCSUnhook()
    /// APC payload (kitty graphics travels here), complete string.
    func parserAPC(_ bytes: ArraySlice<UInt8>)
}

public extension VTParserDelegate {
    func parserPrintASCII(_ bytes: ArraySlice<UInt8>) {
        for byte in bytes { parserPrint(UnicodeScalar(byte)) }
    }

    func parserPrintASCIIAndCRLF(_ bytes: ArraySlice<UInt8>) {
        parserPrintASCII(bytes)
        parserExecute(0x0D)
        parserExecute(0x0A)
    }

    func parserPrintASCIILines(_ bytes: ArraySlice<UInt8>) {
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let start = index
            while index < bytes.endIndex, bytes[index] >= 0x20, bytes[index] <= 0x7E {
                index = bytes.index(after: index)
            }
            parserPrintASCIIAndCRLF(bytes[start..<index])
            guard index < bytes.endIndex else { return }
            index = bytes.index(after: index)
            guard index < bytes.endIndex else { return }
            index = bytes.index(after: index)
        }
    }
}

/// Swift API and delegate lifetime adapter for the native VT parser. Parsing
/// and sequence storage are always in Zig, including standalone parser use.
public final class VTParser {
    enum State: Int {
        case ground, escape, escapeIntermediate, csiEntry, csiParam
        case csiIntermediate, csiIgnore, oscString, dcsEntry, dcsParam
        case dcsIntermediate, dcsPassthrough, dcsIgnore, sosPmString, apcString
    }

    private let native: OpaquePointer
    // Embedded parsers can outlive CmdyTerminal without retaining its facade.
    private let owner: AnyObject?
    public weak var delegate: VTParserDelegate? {
        didSet { onDelegateChanged?(self) }
    }
    var onDelegateChanged: ((VTParser) -> Void)?
    var nativeContext: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }
    static let nativeCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CmdyZigParserEvent>?) -> Void = { context, event in
        guard let context, let event else { return }
        let parser = Unmanaged<VTParser>.fromOpaque(context).takeUnretainedValue()
        parser.receive(event.pointee)
    }

    public init() {
        guard let native = cmdy_zig_parser_create() else {
            preconditionFailure("Cannot allocate CMDY native parser")
        }
        self.native = native
        owner = nil
    }

    init(native raw: OpaquePointer, owner: AnyObject) {
        guard let adapter = cmdy_zig_parser_borrow(UnsafeMutableRawPointer(raw)) else {
            preconditionFailure("Cannot allocate CMDY native parser adapter")
        }
        native = adapter
        self.owner = owner
    }

    deinit { cmdy_zig_parser_free(native) }

    var state: State {
        guard let value = State(rawValue: Int(cmdy_zig_parser_state(native))) else {
            preconditionFailure("Invalid CMDY native parser state")
        }
        return value
    }
    static let maxStringPayload = 65_536
    static let maxParams = 256
    static let maxIntermediates = 16
    public static let colonSeparator = -1

    private func option(_ id: UInt32) -> Bool {
        let value = cmdy_zig_parser_get_option(native, id)
        precondition(value >= 0, "Invalid CMDY native parser option")
        return value != 0
    }
    private func setOption(_ id: UInt32, _ value: Bool) {
        checkedNative(cmdy_zig_parser_set_option(native, id, value ? 1 : 0))
    }
    var coalescesPrintableASCII: Bool {
        get { option(1) }
        set { setOption(1, newValue) }
    }
    var decodesContiguousUTF8: Bool {
        get { option(2) }
        set { setOption(2, newValue) }
    }
    var batchesOrdinaryUnicode: Bool {
        get { option(3) }
        set { setOption(3, newValue) }
    }
    var coalescesCSIParameters: Bool {
        get { option(4) }
        set { setOption(4, newValue) }
    }
    func canContinueOrdinaryUnicodeBatch(for terminal: CmdyTerminal, requiresDelegateIdentity: Bool) -> Bool {
        cmdy_zig_parser_can_continue_unicode(native) != 0 && (!requiresDelegateIdentity || delegate === terminal)
    }

    public func reset() { checkedNative(cmdy_zig_parser_reset(native)) }

    public func feed(_ bytes: ArraySlice<UInt8>) {
        withExtendedLifetime(self) {
            bytes.withUnsafeBufferPointer { input in
                checkedNative(cmdy_zig_parser_feed(native, input.baseAddress, input.count,
                    nativeContext, Self.nativeCallback))
            }
        }
    }
    public func feed(_ bytes: [UInt8]) { feed(bytes[...]) }

    private static func copied<T>(_ pointer: UnsafePointer<T>?, _ count: Int) -> [T] {
        guard count > 0 else { return [] }
        precondition(pointer != nil, "Invalid CMDY native parser callback slice")
        return Array(UnsafeBufferPointer(start: pointer!, count: count))
    }

    private func receive(_ event: CmdyZigParserEvent) {
        // Resolve the weak reference at every original callback boundary. Its
        // receiver remains alive through that call, then may expire before the
        // next event. Copies also preserve slices retained across parser reentry.
        switch event.kind {
        case 1:
            guard let scalar = UnicodeScalar(UInt32(event.argument)) else {
                preconditionFailure("Invalid CMDY native parser scalar")
            }
            delegate?.parserPrint(scalar)
        case 2: delegate?.parserPrintASCII(Self.copied(event.bytes, event.byte_count)[...])
        case 3: delegate?.parserPrintASCIIAndCRLF(Self.copied(event.bytes, event.byte_count)[...])
        case 4: delegate?.parserPrintASCIILines(Self.copied(event.bytes, event.byte_count)[...])
        case 5: delegate?.parserExecute(UInt8(event.argument))
        case 6: delegate?.parserCSI(final: UInt8(event.argument),
            params: Self.copied(event.params, event.param_count), collect: Self.copied(event.collect, event.collect_count))
        case 7: delegate?.parserESC(final: UInt8(event.argument), collect: Self.copied(event.collect, event.collect_count))
        case 8: delegate?.parserOSC(code: event.argument, payload: Self.copied(event.bytes, event.byte_count)[...])
        case 9: delegate?.parserDCSHook(final: UInt8(event.argument),
            params: Self.copied(event.params, event.param_count), collect: Self.copied(event.collect, event.collect_count))
        case 10: delegate?.parserDCSPut(Self.copied(event.bytes, event.byte_count)[...])
        case 11: delegate?.parserDCSUnhook()
        case 12: delegate?.parserAPC(Self.copied(event.bytes, event.byte_count)[...])
        case 13:
            guard let scalar = UnicodeScalar(UInt32(event.argument)), let consumed = event.consumed else {
                preconditionFailure("Invalid CMDY native Unicode callback")
            }
            if let terminal = delegate as? CmdyTerminal {
                consumed.pointee = terminal.parserPrintOrdinaryUnicode(
                    Self.copied(event.bytes, event.byte_count)[...], first: scalar,
                    firstByteCount: event.first_byte_count, sourceParser: self,
                    requiresDelegateIdentity: true)
            } else {
                delegate?.parserPrint(scalar)
            }
        default: preconditionFailure("Invalid CMDY native parser callback kind")
        }
    }
}
