import Foundation

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

public final class VTParser {
    enum State {
        case ground
        case escape
        case escapeIntermediate
        case csiEntry
        case csiParam
        case csiIntermediate
        case csiIgnore
        case oscString
        case dcsEntry
        case dcsParam
        case dcsIntermediate
        case dcsPassthrough
        case dcsIgnore
        case sosPmString      // SOS/PM: collected and dropped
        case apcString        // APC: collected and delivered (kitty)
    }

    private(set) var state: State = .ground
    public weak var delegate: VTParserDelegate?

    // Sequence assembly
    private var params: [Int] = []
    // (params is [0]-seeded — the reference model; no pending value)
    private var collect: [UInt8] = []
    private var oscBuffer: [UInt8] = []
    private var apcBuffer: [UInt8] = []
    private var apcPendingEscape = false
    private var dcsBuffer: [UInt8] = []

    // Caps so an unterminated/adversarial sequence can't grow a buffer without
    // bound (the DCS passthrough already flushes at 4096). On overflow the
    // excess is dropped — no real OSC/APC/param stream approaches these.
    static let maxStringPayload = 65_536   // OSC / APC byte buffers
    static let maxParams = 256
    static let maxIntermediates = 16

    // UTF-8 assembly (ground state)
    private var utf8Pending: [UInt8] = []
    private var utf8Expected = 0

    // Internal test switch: the scalar path remains available as a semantic
    // oracle for the coalesced printable-ASCII path.
    var coalescesPrintableASCII = true

    public init() {}

    public func reset() {
        state = .ground
        clearSequence()
        utf8Pending.removeAll()
        utf8Expected = 0
    }

    private func clearSequence() {
        params.removeAll(keepingCapacity: true)
        params.append(0)
        collect.removeAll(keepingCapacity: true)
    }

    public func feed(_ bytes: ArraySlice<UInt8>) {
        var index = bytes.startIndex
        while index < bytes.endIndex {
            if coalescesPrintableASCII, utf8Expected == 0,
               case .ground = state,
               bytes[index] >= 0x20, bytes[index] <= 0x7E {
                let start = index
                repeat { index = bytes.index(after: index) }
                while index < bytes.endIndex && bytes[index] >= 0x20 && bytes[index] <= 0x7E
                if index < bytes.endIndex, bytes[index] == 0x0D {
                    let next = bytes.index(after: index)
                    if next < bytes.endIndex, bytes[next] == 0x0A {
                        let afterFirst = bytes.index(after: next)
                        var batchEnd = afterFirst
                        var batchLines = 1
                        var scan = afterFirst
                        while scan < bytes.endIndex,
                              bytes[scan] >= 0x20, bytes[scan] <= 0x7E {
                            scan = bytes.index(after: scan)
                            while scan < bytes.endIndex
                                    && bytes[scan] >= 0x20 && bytes[scan] <= 0x7E {
                                scan = bytes.index(after: scan)
                            }
                            guard scan < bytes.endIndex, bytes[scan] == 0x0D else { break }
                            let lf = bytes.index(after: scan)
                            guard lf < bytes.endIndex, bytes[lf] == 0x0A else { break }
                            batchEnd = bytes.index(after: lf)
                            batchLines += 1
                            scan = batchEnd
                        }
                        if batchLines > 1 {
                            delegate?.parserPrintASCIILines(bytes[start..<batchEnd])
                            index = batchEnd
                            continue
                        }
                        delegate?.parserPrintASCIIAndCRLF(bytes[start..<index])
                        index = afterFirst
                        continue
                    }
                }
                delegate?.parserPrintASCII(bytes[start..<index])
            } else {
                step(bytes[index])
                index = bytes.index(after: index)
            }
        }
    }

    public func feed(_ bytes: [UInt8]) {
        feed(bytes[...])
    }

    // MARK: - The machine

    private func step(_ b: UInt8) {
        // CAN/SUB abort any sequence from any state; ESC restarts (except
        // inside OSC/DCS/APC strings, where ESC may begin ST).
        switch state {
        case .ground:
            stepGround(b)
        case .escape:
            stepEscape(b)
        case .escapeIntermediate:
            stepEscapeIntermediate(b)
        case .csiEntry:
            stepCSIEntry(b)
        case .csiParam:
            stepCSIParam(b)
        case .csiIntermediate:
            stepCSIIntermediate(b)
        case .csiIgnore:
            stepCSIIgnore(b)
        case .oscString:
            stepOSC(b)
        case .dcsEntry:
            stepDCSEntry(b)
        case .dcsParam:
            stepDCSParam(b)
        case .dcsIntermediate:
            stepDCSIntermediate(b)
        case .dcsPassthrough:
            stepDCSPassthrough(b)
        case .dcsIgnore:
            stepDCSIgnore(b)
        case .sosPmString:
            stepSOSPM(b)
        case .apcString:
            stepAPC(b)
        }
    }

    /// vt500 "anywhere" rule: string-starting C1 bytes divert from any
    /// sequence state; other high bytes abort to ground and are dropped.
    /// Returns true when the byte was consumed.
    private func divertC1(_ b: UInt8) -> Bool {
        switch b {
        case 0x90: clearSequence(); state = .dcsEntry
        case 0x9B: clearSequence(); state = .csiEntry
        case 0x9D: oscBuffer.removeAll(); oscPendingEscape = false; state = .oscString
        case 0x98, 0x9E: state = .sosPmString
        case 0x9F:
            apcBuffer.removeAll()
            apcPendingEscape = false
            state = .apcString
        case 0x80...0xFF: state = .ground
        default: return false
        }
        return true
    }

    private func enterEscape() {
        // An escape sequence CANCELS a pending UTF-8 assembly, silently
        // (the reference parser's printStateReset clears its putback).
        utf8Pending.removeAll()
        utf8Expected = 0
        clearSequence()
        state = .escape
    }

    // MARK: Ground — printables + UTF-8 + C0

    private func stepGround(_ b: UInt8) {
        if utf8Expected > 0 {
            if b == 0x1B { enterEscape(); return }
            if b < 0x20 {
                // C0 during assembly executes; the assembly persists
                // (print runs are reassembled around control bytes).
                delegate?.parserExecute(b)
                return
            }
            // Any other byte is consumed into the sequence; a strict decode
            // at completion sorts valid from junk (junk → Latin-1 lead, the
            // consumed tail dropped — reference-engine fallback).
            utf8Pending.append(b)
            if utf8Pending.count == utf8Expected {
                flushUTF8()
            }
            return
        }
        switch b {
        case 0x1B:
            enterEscape()
        case 0x00...0x1A, 0x1C...0x1F:
            delegate?.parserExecute(b)
        case 0x20...0x7F:
            delegate?.parserPrint(UnicodeScalar(b))
        case 0x80...0x9F:
            // Raw C1 bytes in ground state are inert. This is deliberately
            // byte-level: a valid UTF-8 sequence whose decoded scalar lies in
            // the C1 range still reaches `parserPrint` through `flushUTF8`.
            return
        case 0xC2...0xDF:
            utf8Pending = [b]; utf8Expected = 2
        case 0xE0...0xEF:
            utf8Pending = [b]; utf8Expected = 3
        case 0xF0...0xF4:
            utf8Pending = [b]; utf8Expected = 4
        default:
            // Not a valid UTF-8 lead: interpret as Latin-1 (the reference
            // engine prints UnicodeScalar(byte) for junk input).
            delegate?.parserPrint(UnicodeScalar(b))
        }
    }

    private enum PendingUTF8Result {
        case scalar(UInt32)
        case malformed(UInt8)
        case empty
    }

    private static func decodePendingUTF8(_ bytes: [UInt8]) -> PendingUTF8Result {
        guard let lead = bytes.first else { return .empty }

        func continuation(_ index: Int) -> UInt8? {
            guard index < bytes.count else { return nil }
            let byte = bytes[index]
            return byte >= 0x80 && byte <= 0xBF ? byte : nil
        }

        switch (lead, bytes.count) {
        case (0xC2...0xDF, 2):
            guard let second = continuation(1) else { return .malformed(lead) }
            return .scalar(UInt32(lead & 0x1F) << 6 | UInt32(second & 0x3F))

        case (0xE0...0xEF, 3):
            guard let second = continuation(1),
                  let third = continuation(2),
                  !(lead == 0xE0 && second < 0xA0),
                  !(lead == 0xED && second > 0x9F) else {
                return .malformed(lead)
            }
            return .scalar(
                UInt32(lead & 0x0F) << 12 |
                UInt32(second & 0x3F) << 6 |
                UInt32(third & 0x3F))

        case (0xF0...0xF4, 4):
            guard let second = continuation(1),
                  let third = continuation(2),
                  let fourth = continuation(3),
                  !(lead == 0xF0 && second < 0x90),
                  !(lead == 0xF4 && second > 0x8F) else {
                return .malformed(lead)
            }
            return .scalar(
                UInt32(lead & 0x07) << 18 |
                UInt32(second & 0x3F) << 12 |
                UInt32(third & 0x3F) << 6 |
                UInt32(fourth & 0x3F))

        default:
            return .malformed(lead)
        }
    }

    private func flushUTF8() {
        let pending = utf8Pending
        utf8Pending.removeAll(keepingCapacity: true)
        utf8Expected = 0

        let value: UInt32
        switch Self.decodePendingUTF8(pending) {
        case .scalar(let scalar):
            value = scalar
        case .malformed(let lead):
            value = UInt32(lead)
        case .empty:
            return
        }
        if let scalar = Unicode.Scalar(value) {
            delegate?.parserPrint(scalar)
        }
    }

    private func stepEscape(_ b: UInt8) {
        switch b {
        case 0x1B: enterEscape()
        case 0x18, 0x1A: state = .ground; delegate?.parserExecute(b)
        case 0x00...0x17, 0x19, 0x1C...0x1F:
            delegate?.parserExecute(b)
        case 0x20...0x2F:
            collect.append(b); state = .escapeIntermediate
        case 0x5B:                     // [
            clearSequence(); state = .csiEntry
        case 0x5D:                     // ]
            oscBuffer.removeAll(); state = .oscString
        case 0x50:                     // P
            clearSequence(); state = .dcsEntry
        case 0x58, 0x5E:               // X (SOS), ^ (PM)
            state = .sosPmString
        case 0x5F:                     // _ (APC)
            apcBuffer.removeAll()
            apcPendingEscape = false
            state = .apcString
        case 0x90:                     // C1 DCS
            clearSequence(); state = .dcsEntry
        case 0x9B:                     // C1 CSI
            clearSequence(); state = .csiEntry
        case 0x9D:                     // C1 OSC
            oscBuffer.removeAll(); state = .oscString
        case 0x98, 0x9E:               // C1 SOS/PM
            state = .sosPmString
        case 0x9F:                     // C1 APC
            apcBuffer.removeAll()
            apcPendingEscape = false
            state = .apcString
        default:
            state = .ground
            delegate?.parserESC(final: b, collect: collect)
        }
    }

    private func stepEscapeIntermediate(_ b: UInt8) {
        switch b {
        case 0x1B: enterEscape()
        case 0x18, 0x1A: state = .ground; delegate?.parserExecute(b)
        case 0x00...0x17, 0x19, 0x1C...0x1F:
            delegate?.parserExecute(b)
        case 0x20...0x2F:
            collect.append(b)
        default:
            state = .ground
            delegate?.parserESC(final: b, collect: collect)
        }
    }

    // MARK: CSI

    private func dispatchCSI(_ final: UInt8) {
        state = .ground
        delegate?.parserCSI(final: final, params: params, collect: collect)
    }

    private func stepCSIEntry(_ b: UInt8) {
        switch b {
        case 0x1B: enterEscape()
        case 0x18, 0x1A: state = .ground; delegate?.parserExecute(b)
        case 0x00...0x17, 0x19, 0x1C...0x1F:
            delegate?.parserExecute(b)
        case 0x30...0x39:
            params[params.count - 1] = Int(b - 0x30); state = .csiParam
        case 0x3B:
            params.append(0); state = .csiParam   // ';' opens the next slot
        case 0x3A:
            // Sub-parameters (SGR 4:3, 38:2::…): treat ':' like ';' but tag
            // the value stream — for now collapse to ';' (engines compare
            // observably; SGR handler resolves colon forms from `collect`).
            collect.append(b); state = .csiParam
        case 0x3C...0x3F:              // private markers < = > ?
            collect.append(b); state = .csiParam
        case 0x20...0x2F:
            collect.append(b); state = .csiIntermediate
        case 0x40...0x7E:
            dispatchCSI(b)
        case 0x80...0xFF:
            _ = divertC1(b)
        default:
            state = .csiIgnore
        }
    }

    private func stepCSIParam(_ b: UInt8) {
        switch b {
        case 0x1B: enterEscape()
        case 0x18, 0x1A: state = .ground; delegate?.parserExecute(b)
        case 0x00...0x17, 0x19, 0x1C...0x1F:
            delegate?.parserExecute(b)
        case 0x30...0x39:
            // Accumulate into the open slot (clamped: unbounded digits must
            // not overflow Int; every consumer clamps to screen bounds long
            // before 0xFFFF matters).
            params[params.count - 1] = min(0xFFFF, params[params.count - 1] * 10 + Int(b - 0x30))
        case 0x3B:
            if params.count < VTParser.maxParams { params.append(0) }
        case 0x3A:
            // Keep the colon-separated value inline; mark separator in the
            // param stream with a sentinel the SGR decoder understands.
            if params.count < VTParser.maxParams {
                params.append(VTParser.colonSeparator)
                params.append(0)
            }
        case 0x3C...0x3F:
            state = .csiIgnore
        case 0x20...0x2F:
            if collect.count < VTParser.maxIntermediates { collect.append(b) }
            state = .csiIntermediate
        case 0x40...0x7E:
            dispatchCSI(b)
        case 0x80...0xFF:
            _ = divertC1(b)
        default:
            state = .csiIgnore
        }
    }

    private func stepCSIIntermediate(_ b: UInt8) {
        switch b {
        case 0x1B: enterEscape()
        case 0x18, 0x1A: state = .ground; delegate?.parserExecute(b)
        case 0x00...0x17, 0x19, 0x1C...0x1F:
            delegate?.parserExecute(b)
        case 0x20...0x2F:
            if collect.count < VTParser.maxIntermediates { collect.append(b) }
        case 0x40...0x7E:
            dispatchCSI(b)
        case 0x80...0xFF:
            state = .ground
        default:
            state = .csiIgnore
        }
    }

    private func stepCSIIgnore(_ b: UInt8) {
        switch b {
        case 0x1B: enterEscape()
        case 0x18, 0x1A: state = .ground; delegate?.parserExecute(b)
        case 0x00...0x17, 0x19, 0x1C...0x1F:
            delegate?.parserExecute(b)
        case 0x40...0x7E:
            state = .ground
        case 0x80...0xFF:
            _ = divertC1(b)
        default:
            break
        }
    }

    /// Sentinel injected between colon-separated params (never a legal
    /// parameter value — params clamp at 0xFFFF).
    public static let colonSeparator = -1

    // MARK: OSC

    private func stepOSC(_ b: UInt8) {
        switch b {
        case 0x07:                     // BEL terminates
            dispatchOSC()
        case 0x1B:
            // Might be ST (ESC \). Peek is impossible in a streaming
            // machine: remember and decide on the next byte.
            state = .oscString
            oscPendingEscape = true
        case 0x18, 0x1A:
            oscBuffer.removeAll(); oscPendingEscape = false
            state = .ground
        default:
            if oscPendingEscape {
                oscPendingEscape = false
                if b == 0x5C {         // ST
                    dispatchOSC()
                    return
                }
                // Not ST: the ESC aborts the OSC and starts a new sequence.
                oscBuffer.removeAll()
                enterEscape()
                step(b)
                return
            }
            if oscBuffer.count < VTParser.maxStringPayload { oscBuffer.append(b) }
        }
    }

    private var oscPendingEscape = false

    private func dispatchOSC() {
        defer { oscBuffer.removeAll(); oscPendingEscape = false; state = .ground }
        var code = 0
        var index = 0
        var sawDigit = false
        while index < oscBuffer.count, oscBuffer[index] >= 0x30, oscBuffer[index] <= 0x39 {
            // Clamp like the CSI param path (real OSC codes are <= 4 digits) —
            // unclamped Int accumulation traps on overflow at ~19 digits.
            code = min(0x10_FFFF, code * 10 + Int(oscBuffer[index] - 0x30))
            sawDigit = true
            index += 1
        }
        if index < oscBuffer.count, oscBuffer[index] == 0x3B {
            index += 1
        } else if !sawDigit {
            code = -1   // malformed: no numeric selector
        }
        delegate?.parserOSC(code: code, payload: oscBuffer[index...])
    }

    // MARK: DCS

    private func stepDCSEntry(_ b: UInt8) {
        switch b {
        case 0x1B: enterEscape()
        case 0x18, 0x1A: state = .ground
        case 0x00...0x17, 0x19, 0x1C...0x1F:
            break                       // ignored in DCS entry
        case 0x30...0x39:
            params[params.count - 1] = Int(b - 0x30); state = .dcsParam
        case 0x3B:
            params.append(0); state = .dcsParam
        case 0x3C...0x3F:
            collect.append(b); state = .dcsParam
        case 0x20...0x2F:
            collect.append(b); state = .dcsIntermediate
        case 0x40...0x7E:
            hookDCS(b)
        default:
            state = .dcsIgnore
        }
    }

    private func stepDCSParam(_ b: UInt8) {
        switch b {
        case 0x1B: enterEscape()
        case 0x18, 0x1A: state = .ground
        case 0x00...0x17, 0x19, 0x1C...0x1F:
            break
        case 0x30...0x39:
            params[params.count - 1] = min(0xFFFF, params[params.count - 1] * 10 + Int(b - 0x30))
        case 0x3B:
            params.append(0)
        case 0x3A, 0x3C...0x3F:
            state = .dcsIgnore
        case 0x20...0x2F:
            collect.append(b); state = .dcsIntermediate
        case 0x40...0x7E:
            hookDCS(b)
        default:
            state = .dcsIgnore
        }
    }

    private func stepDCSIntermediate(_ b: UInt8) {
        switch b {
        case 0x1B: enterEscape()
        case 0x18, 0x1A: state = .ground
        case 0x00...0x17, 0x19, 0x1C...0x1F:
            break
        case 0x20...0x2F:
            collect.append(b)
        case 0x40...0x7E:
            hookDCS(b)
        default:
            state = .dcsIgnore
        }
    }

    private func hookDCS(_ final: UInt8) {
        delegate?.parserDCSHook(final: final, params: params, collect: collect)
        dcsBuffer.removeAll()
        dcsPendingEscape = false
        state = .dcsPassthrough
    }

    private var dcsPendingEscape = false

    private func stepDCSPassthrough(_ b: UInt8) {
        if dcsPendingEscape {
            dcsPendingEscape = false
            if b == 0x5C {              // ST — deliver and unhook
                flushDCS()
                delegate?.parserDCSUnhook()
                state = .ground
                return
            }
            dcsBuffer.append(0x1B)
            // fall through to process b normally
        }
        switch b {
        case 0x1B:
            dcsPendingEscape = true
        case 0x18, 0x1A:
            flushDCS()
            delegate?.parserDCSUnhook()
            state = .ground
        default:
            dcsBuffer.append(b)
            if dcsBuffer.count >= 4096 { flushDCS() }
        }
    }

    private func flushDCS() {
        if !dcsBuffer.isEmpty {
            delegate?.parserDCSPut(dcsBuffer[...])
            dcsBuffer.removeAll(keepingCapacity: true)
        }
    }

    private func stepDCSIgnore(_ b: UInt8) {
        switch b {
        case 0x1B: dcsPendingEscape = true
        case 0x18, 0x1A: state = .ground
        case 0x5C where dcsPendingEscape:
            dcsPendingEscape = false
            state = .ground
        default:
            dcsPendingEscape = false
        }
    }

    // MARK: SOS/PM (dropped) and APC (kitty)


    private func stepSOSPM(_ b: UInt8) {
        switch b {
        case 0x1B:
            // ESC aborts the string INTO an escape sequence (so ESC \ still
            // reads as a clean terminator via the escape state).
            enterEscape()
        case 0x18, 0x1A:
            state = .ground
        case 0x80...0x9F:
            _ = divertC1(b)
        default:
            break                       // 0xA0-0xFF is string content
        }
    }

    private func stepAPC(_ b: UInt8) {
        if apcPendingEscape {
            apcPendingEscape = false
            if b == 0x5C {             // ST — the only APC delivery boundary
                dispatchAPC()
                return
            }

            // A different escape sequence aborts the incomplete APC. Process
            // its final byte normally so ESC _ can begin a fresh APC.
            apcBuffer.removeAll(keepingCapacity: true)
            enterEscape()
            step(b)
            return
        }

        switch b {
        case 0x1B:
            // The reference closes and delivers APC as soon as the ESC
            // prefix of ST arrives. Keep the parser in escape state so a
            // following `\\` is consumed as the ST final, including when
            // the two bytes arrive in separate feed chunks.
            dispatchAPC()
            state = .escape
        case 0x18, 0x1A:
            apcBuffer.removeAll(keepingCapacity: true)
            apcPendingEscape = false
            state = .ground
        case 0x80...0x9F:
            apcBuffer.removeAll(keepingCapacity: true)
            apcPendingEscape = false
            _ = divertC1(b)
        default:
            if apcBuffer.count < VTParser.maxStringPayload { apcBuffer.append(b) }  // incl. 0xA0-0xFF (UTF-8 payloads)
        }
    }

    private func dispatchAPC() {
        let payload = apcBuffer
        apcBuffer.removeAll(keepingCapacity: true)
        apcPendingEscape = false
        state = .ground
        delegate?.parserAPC(payload[...])
    }
}
