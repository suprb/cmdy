# Keybinding import

cmdy can translate selected keybindings from Ghostty, tmux, iTerm2, and macOS
Terminal. Open **Tools → Keybindings**, choose the source, and select its config
or preferences file. The command palette exposes the same four import actions.

Nothing is written during preview. Every source row is classified as:

- **Ready** — a cmdy action or bounded terminal byte sequence is available.
- **Native** — macOS or cmdy already owns the shortcut.
- **Exists** — the shortcut is already in the imported map.
- **Conflict** — two source rows claim the same shortcut.
- **Unsupported** — the source action has no safe cmdy equivalent.
- **Malformed** — the shortcut or source row cannot be decoded.

Apply imports only Ready rows. It rechecks conflicts against the current store,
so a stale preview cannot overwrite a mapping added in the meantime. Imported
maps live in `~/.config/cmdy/keybindings.json`, are written atomically with mode
`0600`, and have a bounded 20-step history. **Undo Last Import** and **Reset
Imported Keybindings** are available in the same menu.

## Source behavior

- **Ghostty** imports representable `keybind = trigger=action` rows. Scoped,
  global, chained, and multi-key triggers remain visible but unsupported when
  their semantics cannot be preserved.
- **tmux** imports only direct `-n` or `-T root` bindings. Prefix-table
  sequences are shown as unsupported rather than flattened into a surprising
  global shortcut.
- **iTerm2** accepts exported JSON or plist keyboard maps and translates known
  actions and bounded text/escape payloads.
- **macOS Terminal** accepts plist data containing `keyMapBoundKeys`, including
  the standard Terminal preferences file and exported `.terminal` profiles.

The importer bounds source files to 8 MB, mappings to 4,096, and any terminal
text payload to 16 KB. Unmodified printable keys are rejected so importing a
map can never replace ordinary terminal typing.
