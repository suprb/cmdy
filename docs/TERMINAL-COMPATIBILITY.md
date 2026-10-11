# CMDY terminal compatibility inventory

Source inspection: September 17, 2026. The active macOS engine is
`Core/Sources/CmdyCoreZig` over `Core/Zig`; the retained Swift implementation is
not the conformance oracle. This is an implementation inventory with explicit
limits, not a claim of universal VT100, VT220 or xterm compatibility.

Independent references: [xterm control sequences, patch 411](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html),
[Kitty keyboard protocol](https://sw.kovidgoyal.net/kitty/keyboard-protocol/), and
[Kitty graphics protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/).
The new `IndependentCompatibilityTests` uses specified reply bytes and fixed
cell expectations; it does not obtain expectations by running the old engine.

## Implemented families and evidence

Paths below are relative to the repository. A listed implementation is not a
claim that every optional variant of that family is implemented.

| Family | Active implementation / supported surface | Regression evidence |
| --- | --- | --- |
| Parsing | `Core/Zig/parser.zig`, `parser_abi.zig`: CSI, ESC, OSC, DCS, APC; incremental feeds and UTF-8 assembly | `VTParserUTF8BoundaryTests`, `VTParserCSIPrefixTests`, `VTParserOwnerDispatchTests` |
| Unicode | `printing.zig`, `ordinary_printing.zig`, `grapheme.zig`, generated Unicode tables: combining marks, variation selectors, ZWJ/emoji, wide-cell ownership | `IndependentCompatibilityTests.testUTF8AndSGRBoundariesAreInvariantAtEveryByteSplit`, `InteriorEmojiBatchTests`, `OrdinaryUnicodeBatchTests`, `CleanRoomTerminalStateTests` |
| Cursor | `dispatch.zig`: CUU/CUD/CUF/CUB, CNL/CPL, CHA/CUP/HVP, VPA/VPR/HPR; save/restore via ESC 7/8 and CSI s/u | `CleanRoomTerminalStateTests`, independent cursor-status test |
| Tabs | `buffer.zig`, `dispatch.zig`: default stops, HT, HTS, CHT, CBT, TBC 0/3 | `CleanRoomTerminalStateTests.testNextTabStopUsesStrictlyLaterBoundedStops`, independent tab/DSR test |
| Editing | `dispatch.zig`: ICH, DCH, IL, DL, ECH, ED, EL, SU, SD, REP | `CleanRoomTerminalStateTests`, `CleanRoomLineAndBackspaceTests`, `AlternateScreenEraseTests` |
| Margins and wrapping | `dispatch.zig`, `printing.zig`: DECSTBM, DECSLRM/DECLRMM, origin, autowrap, reverse wrap, wide-cell/reflow handling | `CleanRoomTerminalStateTests`, `CoreEngineTests.testWideCharsNeverSplitAcrossReflow` |
| Screen buffers | `modes.zig`: 47, 1047, 1048, 1049 and cursor save/restore | `AlternateScreenEraseTests`, independent per-screen keyboard-stack test |
| Basic modes | `modes.zig`: ANSI 4/20; DEC 1/3/5/6/7/9/12/25/40/45/69; mouse/focus/paste/synchronized-update modes below | `IndependentCompatibilityTests.testImplementedPrivateModesReportSetResetAndUnknownExactly` |
| Device replies | `dispatch.zig`: primary/secondary DA, DECID, DSR 5/6, private cursor report; `modes.zig`: DECRQM | Independent byte-exact DSR and DECRQM tests; mode 40 and 45 reporting repaired in this pass |
| Colors and text attributes | `sgr.zig`: normal/bright ANSI, 256 indexed, RGB foreground/background/underline; semicolon/colon forms; bold, faint, italic, blink, inverse, hidden, strike, underline variants | `SGRDispatchTests`, `CleanRoomTerminalStateTests.testSGRNormalAndBrightANSIColorTables` |
| Text metadata | `osc.zig`, `terminal_protocols.zig`: OSC 0/2 title, 7 cwd, 8 hyperlink, 9/99/777 notifications, 133 shell blocks | `CoreEngineTests` title/notification/block tests, `BlockSubscriptionDeliveryTests` |
| Clipboard requests | `osc.zig`: OSC 52 encoded write request, gated by the host; queries deliberately produce no clipboard read | `Core/Zig/osc.zig` native tests; no general clipboard accessed by qualification |
| Status strings | `terminal_protocols.zig`: DECRQSS for SGR, scrolling region and cursor style; negative reply for other requests | Native terminal/protocol cases; limitations below |
| Keyboard negotiation | `modes.zig`: CSI ?u, >u, <u, =u, separate main/alternate stacks; 64 entries each, oldest eviction, reset to zero when popped empty | Independent 100,000-push test and byte-exact flags/query/alternate tests |
| Keyboard emission | `App/CmdyTerminalSurface.swift`: normal/app cursor keys, modifiers, Option-as-Meta, text-system commits, partial Kitty disambiguation | Packaged native exact-byte/dead-key checks; broader client composition checks |
| Mouse and focus | `modes.zig`, `terminal_support.zig`, App surface: 9/1000/1002/1003, protocols 1005/1006/1015, focus 1004 | Core mouse support and packaged native pointer/selection tests; not all xterm mouse extensions |
| Paste | Mode 2004 and App paste path, with begin/end wrappers when enabled | `Tests/test_paste_automation.py`, `Tests/test_paste_runtime_path.py`; native recorder is prepared, but normal-app paste timing is blocked by macOS Automation permission |
| Synchronized updates | Mode 2026, snapshot/scheduling integration | Core mode state, App publication scheduler tests |
| Graphics | `graphics.zig`, `sixel.zig`, `terminal_protocols.zig`: Kitty APC, Sixel DCS and iTerm2 OSC 1337 inline images with owned budgets | Native graphics tests; `NativeGraphicsSnapshotTests`, `NativeGraphicsPublicationTests`, renderer pixel/ownership tests |

## Known unsupported behavior and deviations

- The engine deliberately uses UTF-8 only. ISO-2022 G0–G3 designation, DEC
  Special Graphics and national replacement sets are inert. For example,
  `ESC ( 0 lqk` remains `lqk`; UTF-8 `┌─┐` works. The independent suite preserves
  this explicit limitation; it does not count it as standards conformance.
- ESC `=`/`>` application keypad selection is inert. VT52, Tektronix, printer
  controls, soft fonts and general xterm window-management commands are not a
  supported terminal surface.
- ESC `#8` alignment test is implemented; ESC `#3`–`#6` line-size designation is
  not implemented by the active dispatcher, despite renderer support for line
  modes supplied through its rendering contract.
- DA is a fixed compatibility identification (`?62;1;6;9;22c`, secondary
  `>0;10;1c`). Its advertised legacy feature bits are not an independently
  verified capability negotiation mechanism.
- DECRQSS `m` currently reports reset SGR (`0m`) even with active attributes.
  This is a known reporting deviation. Mode 1048 reporting does not represent a
  persistent saved-cursor state. Private cursor reporting and HVP have legacy
  origin/margin behavior distinct from the normal CUP/DSR path.
- Unsupported CSI prefixes/intermediates are not uniformly filtered before
  dispatch; some may share the ordinary final-byte handler. Unknown sequence
  handling therefore must not be described as fully xterm conformant.
- Kitty flag negotiation is broader than native key emission. All progressive
  enhancement features (release/repeat event types, alternate key identities,
  and associated text for every key) are not fully emitted by the App surface.
- Kitty non-virtual placement retains CMDY's documented historical cursor move:
  default placement resets the column to zero and advances by the placed rows;
  `C=1` suppresses both. This inventory does not change that frozen behavior.
- OSC palette/default-color queries, xterm resource operations, XTGETTCAP and
  unlisted DCS/OSC extensions are not supported. Unlisted variants within an
  implemented family require individual verification.
- Malformed UTF-8 retains the existing Latin-1-lead recovery policy, rather
  than promising Unicode replacement-character behavior for every invalid byte.
  Valid UTF-8, including nonzero slices and every tested split point, is covered.

The installed system input source used for native testing is Swedish. Japanese,
Korean, combining marks and emoji are also exercised directly through the native
`NSTextInputClient` composition contract; this does not claim that a Japanese or
Korean macOS input service was installed or exercised. Qualification reports bind
actual observations to the exact executable and distinguish these two scopes.
