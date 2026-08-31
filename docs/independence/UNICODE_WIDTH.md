# Unicode width independence

CmdyCore's Unicode cell-width implementation is Cmdy-owned and generated only
from versioned data published by the Unicode Consortium. It does not depend on
a terminal-engine vendor, copied width tables, or platform Unicode behavior.

## Pinned source

The generator pins Unicode 17.0.0 and authenticates every download before use:

| Unicode input | SHA-256 |
| --- | --- |
| `ucd/UnicodeData.txt` | `2e1efc1dcb59c575eedf5ccae60f95229f706ee6d031835247d843c11d96470c` |
| `ucd/EastAsianWidth.txt` | `ea7ce50f3444a050333448dffef1cadd9325af55cbb764b4a2280faf52170a33` |
| `ucd/DerivedAge.txt` | `f8ecdf768bdc210f201abd271d9bc587825618a86a7046a8146cc816393f1998` |
| `ucd/HangulSyllableType.txt` | `5a57450afde0d082bc5026f7458649eac3b615490cc7e3d916b0367f1593c0e3` |
| `ucd/PropList.txt` | `130dcddcaadaf071008bdfce1e7743e04fdfbc910886f017d9f9ac931d8c64dd` |
| `ucd/emoji/emoji-data.txt` | `2cb2bb9455cda83e8481541ecf5b6dfda66a3bb89efa3fa7c5297eccf607b72b` |
| `ucd/emoji/emoji-variation-sequences.txt` | `bb3d09ef03f206012c7532dd52dc0a21c9efddba0135ea4cf0d9201b8b9bba7e` |

The property interpretation follows [Unicode Standard Annex #11, *East Asian
Width*](https://www.unicode.org/reports/tr11/tr11-44.html), and [Unicode
Technical Standard #51, *Unicode Emoji*](https://www.unicode.org/reports/tr51/tr51-29.html).
Unicode notes that terminal emulators must tailor East Asian Width for their
own fixed-cell model; the tailoring below is therefore explicit Cmdy policy.

## Cmdy terminal policy

- NUL occupies zero columns; other General Category `Cc` controls are rejected.
- `Mn`, `Mc`, and `Me` combining marks assigned through Unicode 16 occupy zero
  columns. Unicode 17 additions remain one column to preserve Cmdy's existing
  grid behavior until an intentional compatibility migration.
- General Category `Cf`, `Zl`, and `Zp` scalars occupy zero columns, except
  U+00AD SOFT HYPHEN, which remains one column.
- Conjoining Hangul `V`/`T` jamo and the reserved tails U+D7C7–D7CA and
  U+D7FC–D7FF occupy zero columns.
- Emoji modifiers occupy zero independent columns and join their emoji base.
- East Asian `W`/`F` scalars and default emoji-presentation scalars occupy two
  columns.
- East Asian Ambiguous scalars resolve to one column in Cmdy's locale-neutral
  grid; all remaining scalars also occupy one column.
- Emoji variation-sequence bases and regional indicators come directly from
  the pinned Unicode properties. Existing grapheme-cluster handling applies
  VS15, VS16, ZWJ sequences, and flags at the cell layer.

Compatibility is anchored to a dense, black-box scalar-output oracle captured
from the pre-replacement executable. Its SHA-256 is
`0a6c63c371d379dd5cf3c254b88945d29ce66fd471c90719003197488bb2047c`.
The generator reconstructs that digest solely from the official properties and
the documented tailoring above; it fails if any valid scalar changes width.

## Reproduce and verify

From the repository root:

```sh
python3 Core/Tools/UnicodeWidth/generate.py
python3 Core/Tools/UnicodeWidth/generate.py --check
swift test --package-path Core -c release --filter UnicodeWidthTests
```

The generator emits the runtime ranges in
`Core/Sources/CmdyCore/Generated/UnicodeWidthTables.swift` and a separately
shaped, checked-in parity oracle in
`Core/Tests/CmdyCoreTests/Generated/UnicodeWidthParityOracle.swift`. The test
suite checks every valid Unicode scalar plus focused control, combining, CJK,
Hangul, ambiguous-width, emoji, variation-selector, flag, and live terminal-cell
cases.

Unicode data files are © Unicode, Inc. and used under the
[Unicode Terms of Use](https://www.unicode.org/terms_of_use.html).
