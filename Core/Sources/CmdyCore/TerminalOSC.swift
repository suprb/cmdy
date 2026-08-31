import Foundation

// OSC dispatch: title, cwd, hyperlinks, clipboard, and the semantic block
// markers that make blocks a NATIVE buffer structure.
extension CmdyTerminal {

    func dispatchOSC(code: Int, payload: ArraySlice<UInt8>) {
        // Capture the native block boundary before the App's OSC 133 handler
        // can insert host-owned explanation rows at that exact boundary.
        if code == 133 {
            handleBlockMarker(payload)
            oscHandlers[code]?(payload)
            return
        }
        // Other app-registered handlers run before built-in dispatch.
        if let handler = oscHandlers[code] {
            handler(payload)
        }
        switch code {
        case 0, 2:                      // icon+title / title
            title = String(decoding: payload, as: UTF8.self)
            delegate?.setTitle(self, title: title)
        case 1:
            break                        // icon only — ignored
        case 4:
            break                        // palette set — front-end concern
        case 7:                          // cwd
            let dir = String(decoding: payload, as: UTF8.self)
            delegate?.setCurrentDirectory(self, directory: dir.isEmpty ? nil : dir)
        case 8:                          // hyperlink open/close
            handleHyperlink(payload)
        case 9:                          // iTerm2/ConEmu notification
            let message = String(decoding: payload, as: UTF8.self)
            if !message.isEmpty { delegate?.notify(self, title: message, body: "") }
        case 99:                         // kitty notification (simple form:
            // metadata;payload — we surface the payload; full multi-chunk
            // kitty protocol is out of scope until something needs it)
            let text = String(decoding: payload, as: UTF8.self)
            if let sep = text.firstIndex(of: ";") {
                let body = String(text[text.index(after: sep)...])
                if !body.isEmpty { delegate?.notify(self, title: body, body: "") }
            }
        case 777:                        // rxvt extension: notify;title;body
            let parts = String(decoding: payload, as: UTF8.self)
                .split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
            if parts.first == "notify", parts.count >= 2 {
                delegate?.notify(self, title: String(parts[1]),
                                 body: parts.count > 2 ? String(parts[2]) : "")
            }
        case 52:                         // clipboard (write; reads are policy-denied)
            handleClipboard(payload)
        case 1337:                       // iTerm2 inline images (File=…)
            handleITerm2(payload)
        default:
            break
        }
    }

    // MARK: OSC 8 — hyperlinks

    private func handleHyperlink(_ payload: ArraySlice<UInt8>) {
        // format: params;URI — empty URI closes the link run.
        let text = String(decoding: payload, as: UTF8.self)
        guard let sep = text.firstIndex(of: ";") else { return }
        let uri = String(text[text.index(after: sep)...])
        if uri.isEmpty {
            activeLinkId = 0
        } else {
            linkTable.append(uri)
            activeLinkId = UInt16(clamping: linkTable.count)
        }
    }

    /// Resolve a cell's linkId to its URI.
    public func linkURI(id: UInt16) -> String? {
        let index = Int(id) - 1
        guard index >= 0, index < linkTable.count else { return nil }
        return linkTable[index]
    }

    // MARK: OSC 52 — clipboard

    private func handleClipboard(_ payload: ArraySlice<UInt8>) {
        // format: selection;base64 — "?" queries (denied: never leak the
        // clipboard to a program without the host's consent).
        let text = String(decoding: payload, as: UTF8.self)
        guard let sep = text.firstIndex(of: ";") else { return }
        let b64 = String(text[text.index(after: sep)...])
        guard b64 != "?" else { return }
        if let data = Data(base64Encoded: b64) {
            delegate?.clipboardCopy(self, content: data)
        }
    }

    // MARK: OSC 133 — blocks, native

    private func handleBlockMarker(_ payload: ArraySlice<UInt8>) {
        synchronizeBlockRowsToScrollback()
        let text = String(decoding: payload, as: UTF8.self)
        let parts = text.split(separator: ";", omittingEmptySubsequences: false)
        guard let kind = parts.first?.first else { return }
        let absoluteRow = buffer.yBase + buffer.y
        switch kind {
        case "A":
            blocks.promptStarted(row: absoluteRow, timestamp: delegate?.now(self) ?? 0)
        case "B":
            blocks.promptEnded(row: absoluteRow, col: buffer.x)
        case "C":
            blocks.commandStarted(row: absoluteRow)
        case "D":
            let exit = parts.count > 1 ? Int(parts[1]) : nil
            let block = blocks.commandFinished(
                row: absoluteRow, exitCode: exit,
                timestamp: delegate?.now(self) ?? 0)
            if let exit, exit != 0,
               let block,
               let provider = commandFinishedHostMessageProvider,
               let message = provider(commandText(for: block), outputText(for: block),
                                      Int32(exit)) {
                insertHostMessage(message)
            }
        default:
            break
        }
    }

    private func commandText(for block: TerminalBlock) -> String {
        guard let start = block.inputStart, block.commandRow > start.row else { return "" }
        return (start.row..<block.commandRow).compactMap { row in
            if row == start.row {
                return scrollbackLineText(row: row, columns: start.col..<cols)
            }
            return scrollbackLineText(row: row)
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func outputText(for block: TerminalBlock) -> String {
        guard let end = block.endRow, end > block.commandRow else { return "" }
        var text = ""
        for row in block.commandRow..<end {
            if row > block.commandRow, !isBufferRowWrapped(row) { text += "\n" }
            text += scrollbackLineText(row: row) ?? ""
        }
        return text.trimmingCharacters(in: .newlines)
    }
}
