# Cell text compatibility

`Core/Zig/cell_text.zig` implements the first extended grapheme of each cell,
matching the existing Swift `Cell.character` and `Cell.text` accessors. It does
not alter stored scalars, extras, widths, attributes, or mutation versions.
`Line.trimmedText`, the legacy C text query, and native block text extraction
use this projection. Blank cells still become spaces when composing row text.

The property data implements [UAX #29 revision 45](https://www.unicode.org/reports/tr29/tr29-45.html)
and is pinned to Unicode 16.0.0 for the Swift 6.2.4/macOS 26 text contract.
The terminal-width tables remain separately pinned to Unicode 17.0.0.
No Swift or platform text segmentation routine runs in the native engine.
Future Unicode upgrades must qualify these two policies separately.

`generate.py` authenticates the versioned Unicode source files with SHA-256,
then generates `grapheme_properties.zig` and the compact conformance fixture
`testdata/grapheme_break_tests.bin`. The Unicode data license is included here.

```sh
python3 Core/Tools/ZigEngine/Grapheme/generate.py --cache /path/to/unicode-cache --check
```

`validate.py` freezes its native candidate and unchanged production Swift
`Cell.swift`, builds an actual Swift/C/Zig comparison executable, and retains
source pins, commands, exit statuses, process IDs, and comparison output. It
compares all valid Unicode scalars in four independent contexts, every CMDY
zero-width scalar in 17 contexts, the published grapheme cases, and malformed
raw cell values. Expected bytes come directly from frozen `Cell.text` using
Swift `String.first`; the comparison does not reproduce the native rules.

```sh
python3 Core/Tools/ZigEngine/Grapheme/validate.py \
  --frozen-core /path/to/unchanged/Core \
  --cache /path/to/unicode-cache \
  --output /path/to/new-evidence-directory
```

Native tests in `cell_text.zig` verify all 1,093 published grapheme boundary
cases and allocation failures. `cell_text_tests.zig` covers actual chunked
terminal parsing, raw values, legacy C output, and failed-command input/output
callbacks. Run it in both Debug and ReleaseSafe, using separate evidence/cache
directories. This is correctness qualification; it makes no timing claim.
