import Foundation

// SM/RM + DEC private modes, DECRQM reporting, and alt-screen switching.
extension CmdyTerminal {

    func setModes(_ params: [Int], collect: [UInt8], value: Bool) {
        let isPrivate = collect.first == UInt8(ascii: "?")
        for p in params {
            if isPrivate { setPrivateMode(p, value) } else { setAnsiMode(p, value) }
        }
    }

    private func setAnsiMode(_ mode: Int, _ value: Bool) {
        switch mode {
        case 4: insertMode = value           // IRM
        case 20: lineFeedMode = value        // LNM
        default: break
        }
    }

    func setPrivateMode(_ mode: Int, _ value: Bool) {
        let buf = buffer
        switch mode {
        case 1: applicationCursorKeys = value            // DECCKM
        case 3:                                          // DECCOLM 80⇄132
            if allow80To132 {
                resize(cols: value ? 132 : 80, rows: buf.rows)
                fullReset()
            }
        case 5:                                          // DECSCNM — the PEN
            // flips to the inverted attr (reference behavior), not a flag
            reverseVideo = value
            currentAttribute = value
                ? CellAttribute(fg: .defaultInverted, bg: .defaultInverted)
                : .empty
        case 6:                                          // DECOM — the flag
            originMode = value                           // flips; NO homing
        case 7: autoWrap = value                         // DECAWM
        case 9: mouseMode = value ? .x10 : .off
        case 12: cursorBlink = value
        case 25: cursorHidden = !value                   // DECTCEM
        case 40: allow80To132 = value                    // 80↔132 gate
        case 45:                                         // xterm reverse wrap —
            // enabling REQUIRES DECAWM on (reference gate); disabling is free
            if value {
                if autoWrap { reverseWraparound = true }
            } else {
                reverseWraparound = false
            }
        case 69: marginMode = value                      // DECLRMM
        case 47:                                         // alt screen, plain
            if value {
                switchToAltBuffer(clear: true, saveCursor: false)
                cursorHidden = false     // alt-ENTER also force-shows
            } else {
                switchToNormalBuffer(restoreCursor: false)
                cursorHidden = false     // alt-exit force-shows (reference)
            }
        case 1000: mouseMode = value ? .vt200 : .off
        case 1002: mouseMode = value ? .buttonEvent : .off
        case 1003: mouseMode = value ? .anyEvent : .off
        case 1004: focusReporting = value
        case 1005:
            mouseProtocol = value ? .utf8 : .x10
            if !value { mouseMode = .off }
        case 1006:
            mouseProtocol = value ? .sgr : .x10
            if !value { mouseMode = .off }
        case 1015:
            mouseProtocol = value ? .urxvt : .x10
            if !value { mouseMode = .off }
        case 1047:
            if value {
                switchToAltBuffer(clear: true, saveCursor: false)
                cursorHidden = false
            } else {
                switchToNormalBuffer(restoreCursor: false)
                cursorHidden = false
            }
        case 1048:
            if value { saveCursor() } else { restoreCursor() }
        case 1049:                                       // the modern TUI pair
            if value {
                switchToAltBuffer(clear: true, saveCursor: true)
                cursorHidden = false
            } else {
                switchToNormalBuffer(restoreCursor: true)
                cursorHidden = false
            }
        case 2004: bracketedPaste = value
        case 2026: synchronizedUpdates = value
        default: break
        }
        _ = buf
    }


    func privateModeValue(_ mode: Int) -> Bool {
        switch mode {
        case 1: return applicationCursorKeys
        case 5: return reverseVideo
        case 6: return originMode
        case 7: return autoWrap
        case 9: return mouseMode == .x10
        case 12: return cursorBlink
        case 25: return !cursorHidden
        case 47, 1047, 1049: return isAlternateBuffer
        case 45: return reverseWraparound
        case 69: return marginMode
        case 1000: return mouseMode == .vt200
        case 1002: return mouseMode == .buttonEvent
        case 1003: return mouseMode == .anyEvent
        case 1004: return focusReporting
        case 1005: return mouseProtocol == .utf8
        case 1006: return mouseProtocol == .sgr
        case 1015: return mouseProtocol == .urxvt
        case 2004: return bracketedPaste
        case 2026: return synchronizedUpdates
        default: return false
        }
    }

    /// DECRQM — report a mode's state: CSI ? Pm ; Ps $ y
    func reportMode(_ mode: Int, isPrivate: Bool) {
        if isPrivate {
            let known: Set<Int> = [1, 5, 6, 7, 9, 12, 25, 47, 69, 1000, 1002, 1003,
                                   1004, 1005, 1006, 1015, 1047, 1048, 1049, 2004, 2026]
            let status: Int
            if known.contains(mode) {
                status = privateModeValue(mode) ? 1 : 2
            } else {
                status = 0
            }
            sendResponse("\u{1b}[?\(mode);\(status)$y")
        } else {
            let status: Int
            switch mode {
            case 4: status = insertMode ? 1 : 2
            case 20: status = lineFeedMode ? 1 : 2
            default: status = 0
            }
            sendResponse("\u{1b}[\(mode);\(status)$y")
        }
    }

    // MARK: - Alt screen

    func switchToAltBuffer(clear: Bool, saveCursor save: Bool) {
        guard !isAlternateBuffer else { return }
        if save { saveCursor() }
        // The alt screen adopts the normal screen's geometry + cursor, and
        // its viewport is ALWAYS refilled with the plain default attribute
        // (reference fillViewportRows(attribute: nil) — never the pen's bg).
        altBuffer.resizeSimple(newCols: normalBuffer.cols, newRows: normalBuffer.rows,
                               fill: Cell())
        altBuffer.x = normalBuffer.x
        altBuffer.y = normalBuffer.y
        isAlternateBuffer = true
        for r in 0..<altBuffer.rows {
            let line = altBuffer.liveLine(r)
            line.fill(with: Cell())
            line.isWrapped = false
            line.images = nil
            line.renderMode = .single
        }
        _ = clear
    }

    func switchToNormalBuffer(restoreCursor restore: Bool) {
        guard isAlternateBuffer else { return }
        // The cursor rides across the switch (the alt session's position
        // lands in the normal buffer); DECRC then restores for 1049.
        normalBuffer.x = altBuffer.x
        normalBuffer.y = min(altBuffer.y, normalBuffer.rows - 1)
        isAlternateBuffer = false
        if restore { restoreCursor() }
    }

    // MARK: - Kitty keyboard protocol (CSI u family)

    func kittyKeyboardCSIu(final: UInt8, params: [Int], collect: [UInt8]) {
        guard final == UInt8(ascii: "u") else { return }
        switch collect.first {
        case UInt8(ascii: "?"):                       // query
            sendResponse("\u{1b}[?\(kittyKeyboardFlags)u")
        case UInt8(ascii: ">"):                       // push
            pushKittyFlags(params.first ?? 0)
        case UInt8(ascii: "<"):                       // pop
            popKittyFlags(params.first ?? 1)
        case UInt8(ascii: "="):                       // set
            setKittyFlags(params.first ?? 0, mode: params.count > 1 ? params[1] : 1)
        default:
            break
        }
    }

    private func pushKittyFlags(_ flags: Int) {
        if isAlternateBuffer { kittyKeyboardStackAlt.append(flags) }
        else { kittyKeyboardStackNormal.append(flags) }
    }

    private func popKittyFlags(_ n: Int) {
        for _ in 0..<max(1, n) {
            if isAlternateBuffer { _ = kittyKeyboardStackAlt.popLast() }
            else { _ = kittyKeyboardStackNormal.popLast() }
        }
    }

    private func setKittyFlags(_ flags: Int, mode: Int) {
        var stack = isAlternateBuffer ? kittyKeyboardStackAlt : kittyKeyboardStackNormal
        let current = stack.last ?? 0
        let updated: Int
        switch mode {
        case 2: updated = current | flags
        case 3: updated = current & ~flags
        default: updated = flags
        }
        if stack.isEmpty { stack.append(updated) } else { stack[stack.count - 1] = updated }
        if isAlternateBuffer { kittyKeyboardStackAlt = stack }
        else { kittyKeyboardStackNormal = stack }
    }
}
