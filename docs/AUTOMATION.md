# Terminal automation

## Paste text with AppleScript

The packaged macOS app exposes existing terminal panes through its scripting
dictionary. Each terminal has a stable `id` and a read-only `name`.

```applescript
tell application "cmdy"
    set paneID to id of terminal 1
    input text "hello from AppleScript" to terminal id paneID
end tell
```

`input text` follows the same paste policy as an ordinary paste: a pane can
replace or reject the text, accepted input cancels text composition, and the
terminal's bracketed-paste mode determines framing. The command does not add
Return, activate a pane, or read or write the system clipboard. Multiline text
is passed through as supplied. macOS applies its normal Automation permissions
to the calling application.

Keep the terminal ID when targeting a particular pane. A closed pane is an
error; CMDY does not redirect its input to the newly focused pane. The collection
contains existing terminal panes and does not create windows.

The supported interface is deliberately small:

| Interface | Meaning |
|---|---|
| `terminals` | Existing terminal panes |
| `id of terminal` | Stable pane identifier |
| `name of terminal` | Window title |
| `input text <text> to <terminal>` | Insert text through the normal paste path |

The public Apple Event codes for `terminal` and `input text` match Ghostty's
published scripting interface, so a client can use the same transport with an
explicit process and terminal ID. This is a compatibility subset; other
Ghostty scripting commands are not exposed.

`package.sh` installs `App/Resources/Cmdy.sdef` at
`Contents/Resources/Cmdy.sdef` and declares it in `Info.plist`. A bare SwiftPM
executable has no app-bundle scripting dictionary. Headless regression tests
are in `Tests/test_paste_automation.py`; native paste-to-visible-frame
measurement is a separate benchmark qualification.

## Export retained output to a file

The keybinding importer supports `write_scrollback_file:paste`. For example,
import this Ghostty-format row through **Tools → Keybindings**, choosing an
unused shortcut in the preview:

```text
keybind = ctrl+shift+2=write_scrollback_file:paste
```

The action writes every retained row of the focused terminal's current buffer
to a new private UTF-8 temporary file, then inserts the file path into that
terminal. It does not add Return or use the clipboard. Scrolling the viewport
does not change which retained rows are exported; an alternate screen exports
its own active buffer. Physical wraps remain line breaks, and wide-character
continuation cells do not add extra spaces to the text.

Files are created exclusively with mode `0600`. Existing files and leaf
symlinks are not replaced, and a failed write does not insert a path. This
action currently supports the `paste` argument. See the
[keybinding import reference](KEYBINDING_IMPORT.md) for preview and conflict
handling.
