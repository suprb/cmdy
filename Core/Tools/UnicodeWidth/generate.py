#!/usr/bin/env python3
"""Generate CmdyCore's pinned Unicode terminal-width tables.

The generator consumes only versioned files published by the Unicode
Consortium. Every input is authenticated before parsing, and both generated
Swift files are deterministic. Run with --check in CI to detect drift.
"""

from __future__ import annotations

import argparse
import hashlib
import pathlib
import subprocess
import tempfile
from dataclasses import dataclass
from typing import Iterable


UNICODE_VERSION = "17.0.0"
MAX_CODE_POINT = 0x10FFFF
PARITY_ORACLE_SHA256 = "0a6c63c371d379dd5cf3c254b88945d29ce66fd471c90719003197488bb2047c"


@dataclass(frozen=True)
class Source:
    path: str
    sha256: str

    @property
    def url(self) -> str:
        return f"https://www.unicode.org/Public/{UNICODE_VERSION}/{self.path}"


SOURCES = (
    Source(
        "ucd/UnicodeData.txt",
        "2e1efc1dcb59c575eedf5ccae60f95229f706ee6d031835247d843c11d96470c",
    ),
    Source(
        "ucd/EastAsianWidth.txt",
        "ea7ce50f3444a050333448dffef1cadd9325af55cbb764b4a2280faf52170a33",
    ),
    Source(
        "ucd/DerivedAge.txt",
        "f8ecdf768bdc210f201abd271d9bc587825618a86a7046a8146cc816393f1998",
    ),
    Source(
        "ucd/HangulSyllableType.txt",
        "5a57450afde0d082bc5026f7458649eac3b615490cc7e3d916b0367f1593c0e3",
    ),
    Source(
        "ucd/PropList.txt",
        "130dcddcaadaf071008bdfce1e7743e04fdfbc910886f017d9f9ac931d8c64dd",
    ),
    Source(
        "ucd/emoji/emoji-data.txt",
        "2cb2bb9455cda83e8481541ecf5b6dfda66a3bb89efa3fa7c5297eccf607b72b",
    ),
    Source(
        "ucd/emoji/emoji-variation-sequences.txt",
        "bb3d09ef03f206012c7532dd52dc0a21c9efddba0135ea4cf0d9201b8b9bba7e",
    ),
)


Range = tuple[int, int]


def parse_range(field: str) -> Range:
    bounds = field.strip().split("..", maxsplit=1)
    lower = int(bounds[0], 16)
    upper = int(bounds[1], 16) if len(bounds) == 2 else lower
    if lower > upper or upper > MAX_CODE_POINT:
        raise ValueError(f"invalid Unicode range: {field}")
    return lower, upper


def merged(ranges: Iterable[Range]) -> list[Range]:
    result: list[Range] = []
    for lower, upper in sorted(ranges):
        if result and lower <= result[-1][1] + 1:
            result[-1] = (result[-1][0], max(result[-1][1], upper))
        else:
            result.append((lower, upper))
    return result


def subtracted(ranges: Iterable[Range], removed: Iterable[Range]) -> list[Range]:
    result: list[Range] = []
    exclusions = merged(removed)
    for lower, upper in merged(ranges):
        cursor = lower
        for excluded_lower, excluded_upper in exclusions:
            if excluded_upper < cursor:
                continue
            if excluded_lower > upper:
                break
            if excluded_lower > cursor:
                result.append((cursor, min(upper, excluded_lower - 1)))
            cursor = max(cursor, excluded_upper + 1)
            if cursor > upper:
                break
        if cursor <= upper:
            result.append((cursor, upper))
    return result


def contains(ranges: list[Range], value: int) -> bool:
    low = 0
    high = len(ranges)
    while low < high:
        middle = low + (high - low) // 2
        lower, upper = ranges[middle]
        if value < lower:
            high = middle
        elif value > upper:
            low = middle + 1
        else:
            return True
    return False


def parsed_property_file(path: pathlib.Path) -> dict[str, list[Range]]:
    properties: dict[str, list[Range]] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        data = raw_line.split("#", maxsplit=1)[0].strip()
        if not data:
            continue
        fields = [field.strip() for field in data.split(";")]
        if len(fields) < 2:
            raise ValueError(f"malformed property line in {path}: {raw_line}")
        properties.setdefault(fields[1], []).append(parse_range(fields[0]))
    return {name: merged(ranges) for name, ranges in properties.items()}


def parsed_general_categories(path: pathlib.Path) -> dict[str, list[Range]]:
    categories: dict[str, list[Range]] = {}
    pending_first: tuple[int, str, str] | None = None

    for raw_line in path.read_text(encoding="utf-8").splitlines():
        fields = raw_line.split(";")
        if len(fields) != 15:
            raise ValueError(f"malformed UnicodeData line: {raw_line}")
        value = int(fields[0], 16)
        name = fields[1]
        category = fields[2]

        if name.endswith(", First>"):
            if pending_first is not None:
                raise ValueError("nested UnicodeData First range")
            pending_first = (value, name.removesuffix(", First>"), category)
            continue
        if name.endswith(", Last>"):
            if pending_first is None:
                raise ValueError("UnicodeData Last without First")
            lower, first_name, first_category = pending_first
            if name.removesuffix(", Last>") != first_name or category != first_category:
                raise ValueError("mismatched UnicodeData First/Last range")
            categories.setdefault(category, []).append((lower, value))
            pending_first = None
            continue
        categories.setdefault(category, []).append((value, value))

    if pending_first is not None:
        raise ValueError("unterminated UnicodeData First range")
    return {name: merged(ranges) for name, ranges in categories.items()}


def parsed_vs16_bases(path: pathlib.Path) -> list[Range]:
    bases: list[Range] = []
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        data = raw_line.split("#", maxsplit=1)[0].strip()
        if not data:
            continue
        fields = [field.strip() for field in data.split(";")]
        sequence = fields[0].split()
        if len(sequence) != 2:
            raise ValueError(f"unexpected emoji variation sequence: {raw_line}")
        if sequence[1].upper() == "FE0F":
            value = int(sequence[0], 16)
            bases.append((value, value))
    return merged(bases)


def authenticated_inputs(data_root: pathlib.Path) -> dict[str, pathlib.Path]:
    inputs: dict[str, pathlib.Path] = {}
    for source in SOURCES:
        path = data_root / source.path
        if not path.is_file():
            raise FileNotFoundError(path)
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if digest != source.sha256:
            raise ValueError(
                f"SHA-256 mismatch for {source.path}: expected {source.sha256}, got {digest}"
            )
        inputs[source.path] = path
    return inputs


def download_inputs(data_root: pathlib.Path) -> None:
    for source in SOURCES:
        destination = data_root / source.path
        destination.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            [
                "curl",
                "--fail",
                "--location",
                "--silent",
                "--show-error",
                "--user-agent",
                "Cmdy-UnicodeWidth-Generator/1",
                "--output",
                str(destination),
                source.url,
            ],
            check=True,
        )


@dataclass(frozen=True)
class Tables:
    controls: list[Range]
    zero_width: list[Range]
    wide: list[Range]
    ambiguous: list[Range]
    regional_indicators: list[Range]
    emoji_vs16_bases: list[Range]


def build_tables(inputs: dict[str, pathlib.Path]) -> Tables:
    general = parsed_general_categories(inputs["ucd/UnicodeData.txt"])
    east_asian = parsed_property_file(inputs["ucd/EastAsianWidth.txt"])
    age = parsed_property_file(inputs["ucd/DerivedAge.txt"])
    hangul = parsed_property_file(inputs["ucd/HangulSyllableType.txt"])
    properties = parsed_property_file(inputs["ucd/PropList.txt"])
    emoji = parsed_property_file(inputs["ucd/emoji/emoji-data.txt"])

    # Terminal tailoring chosen by CmdyCore:
    # - the combining repertoire is compatibility-frozen through Unicode 16;
    # - format controls are zero-width except the printable soft hyphen;
    # - conjoining Hangul vowels/trailing consonants join the leading jamo;
    # - emoji modifiers join their emoji base and occupy no independent cell;
    # - East_Asian_Width W/F and default emoji presentation occupy two cells;
    # - East_Asian_Width A resolves narrow in Cmdy's locale-neutral grid.
    combining = subtracted(
        general["Mn"] + general["Mc"] + general["Me"],
        age["17.0"],
    )
    format_controls = subtracted(general["Cf"], [(0x00AD, 0x00AD)])
    zero_width = merged(
        combining
        + format_controls
        + general["Zl"]
        + general["Zp"]
        + hangul["V"]
        + hangul["T"]
        # Reserved tails of the two Hangul Extended-B conjoining ranges stay
        # zero-width so assignment changes cannot alter legacy cell geometry.
        + [(0xD7C7, 0xD7CA), (0xD7FC, 0xD7FF)]
        + emoji["Emoji_Modifier"]
    )
    wide = merged(east_asian["W"] + east_asian["F"] + emoji["Emoji_Presentation"])

    tables = Tables(
        controls=general["Cc"],
        zero_width=zero_width,
        wide=wide,
        ambiguous=east_asian["A"],
        regional_indicators=properties["Regional_Indicator"],
        emoji_vs16_bases=parsed_vs16_bases(
            inputs["ucd/emoji/emoji-variation-sequences.txt"]
        ),
    )
    validate_tables(tables)
    return tables


def width(value: int, tables: Tables) -> int:
    if value == 0:
        return 0
    if contains(tables.controls, value):
        return -1
    if contains(tables.zero_width, value):
        return 0
    if contains(tables.wide, value):
        return 2
    return 1


def validate_tables(tables: Tables) -> None:
    expectations = {
        0x0000: 0,
        0x0007: -1,
        0x0041: 1,
        0x00AD: 1,
        0x0600: 0,
        0x0301: 0,
        0x093E: 0,
        0x1161: 0,
        0x11A8: 0,
        0x115F: 2,
        0x2028: 0,
        0x200D: 0,
        0x2764: 1,
        0x4E00: 2,
        0x1ACF: 1,
        0x1F1E6: 2,
        0x1F3FB: 0,
        0x1F600: 2,
    }
    for value, expected in expectations.items():
        actual = width(value, tables)
        if actual != expected:
            raise ValueError(f"policy invariant failed for U+{value:04X}: {actual} != {expected}")
    if not contains(tables.regional_indicators, 0x1F1E6):
        raise ValueError("Regional_Indicator data is missing U+1F1E6")
    if contains(tables.regional_indicators, 0x1F1E5):
        raise ValueError("Regional_Indicator data starts too early")
    if not contains(tables.emoji_vs16_bases, 0x0023):
        raise ValueError("emoji VS16 base data is missing U+0023")
    if contains(tables.emoji_vs16_bases, 0x0041):
        raise ValueError("emoji VS16 base data incorrectly contains U+0041")
    digest = hashlib.sha256(parity_bytes(tables)).hexdigest()
    if digest != PARITY_ORACLE_SHA256:
        raise ValueError(
            "width policy no longer matches the frozen Cmdy parity oracle: "
            f"expected {PARITY_ORACLE_SHA256}, got {digest}"
        )


def parity_bytes(tables: Tables) -> bytes:
    return bytes(
        0x7F if 0xD800 <= value <= 0xDFFF else width(value, tables) & 0xFF
        for value in range(MAX_CODE_POINT + 1)
    )


def scalar_literal(value: int) -> str:
    digits = 4 if value <= 0xFFFF else 6
    return f"0x{value:0{digits}X}"


def swift_ranges(name: str, ranges: list[Range]) -> str:
    lines = [f"    static let {name}: [CmdyUnicodeScalarRange] = ["]
    for lower, upper in ranges:
        lines.append(
            f"        .init({scalar_literal(lower)}, {scalar_literal(upper)}),"
        )
    lines.append("    ]")
    return "\n".join(lines)


def generated_header() -> str:
    source_lines = "\n".join(
        f"//   {source.path} SHA-256 {source.sha256}" for source in SOURCES
    )
    return f"""// Generated by Core/Tools/UnicodeWidth/generate.py. DO NOT EDIT.
// Unicode version: {UNICODE_VERSION}
// Inputs:
{source_lines}
//
// Unicode data files are © Unicode, Inc. and used under the Unicode Terms of Use:
// https://www.unicode.org/terms_of_use.html
"""


def runtime_source(tables: Tables) -> str:
    source_metadata = "\n".join(
        f'        .init(path: "{source.path}", sha256: "{source.sha256}"),'
        for source in SOURCES
    )
    sections = [
        generated_header(),
        """
struct CmdyUnicodeScalarRange: Sendable {
    let lowerBound: UInt32
    let upperBound: UInt32

    init(_ lowerBound: UInt32, _ upperBound: UInt32) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }
}

enum GeneratedUnicodeWidthTables {
    struct SourceDigest: Sendable {
        let path: StaticString
        let sha256: StaticString
    }

    static let unicodeVersion = """ + f'"{UNICODE_VERSION}"' + """
    static let sourceDigests: [SourceDigest] = [
""" + source_metadata + """
    ]
""",
        swift_ranges("controls", tables.controls),
        swift_ranges("zeroWidth", tables.zero_width),
        swift_ranges("wide", tables.wide),
        swift_ranges("ambiguous", tables.ambiguous),
        swift_ranges("regionalIndicators", tables.regional_indicators),
        swift_ranges("emojiVS16Bases", tables.emoji_vs16_bases),
        "}\n",
    ]
    return "\n\n".join(sections)


def oracle_runs(tables: Tables) -> list[tuple[int, int, int]]:
    result: list[tuple[int, int, int]] = []
    lower = 0
    current_width = width(0, tables)
    for value in range(1, MAX_CODE_POINT + 1):
        next_width = width(value, tables)
        if next_width != current_width:
            result.append((lower, value - 1, current_width))
            lower = value
            current_width = next_width
    result.append((lower, MAX_CODE_POINT, current_width))
    return result


def oracle_source(tables: Tables) -> str:
    lines = [
        generated_header(),
        """
struct UnicodeWidthParityRun {
    let lowerBound: UInt32
    let upperBound: UInt32
    let width: Int
}

enum GeneratedUnicodeWidthParityOracle {
    static let unicodeVersion = """ + f'"{UNICODE_VERSION}"' + """
    static let sha256 = """ + f'"{PARITY_ORACLE_SHA256}"' + """
    static let runs: [UnicodeWidthParityRun] = [""",
    ]
    for lower, upper, run_width in oracle_runs(tables):
        lines.append(
            "        .init(lowerBound: "
            f"{scalar_literal(lower)}, upperBound: {scalar_literal(upper)}, "
            f"width: {run_width}),"
        )
    lines.append("    ]\n}\n")
    return "\n".join(lines)


def emit(path: pathlib.Path, content: str, check: bool) -> bool:
    content = content.rstrip() + "\n"
    if check:
        existing = path.read_text(encoding="utf-8") if path.is_file() else None
        if existing != content:
            print(f"out of date: {path}")
            return False
        print(f"verified: {path}")
        return True
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8", newline="\n")
    print(f"generated: {path}")
    return True


def generate(data_root: pathlib.Path, output_root: pathlib.Path, check: bool) -> bool:
    inputs = authenticated_inputs(data_root)
    tables = build_tables(inputs)
    runtime_path = output_root / "Sources/CmdyCore/Generated/UnicodeWidthTables.swift"
    oracle_path = output_root / "Tests/CmdyCoreTests/Generated/UnicodeWidthParityOracle.swift"
    return all(
        (
            emit(runtime_path, runtime_source(tables), check),
            emit(oracle_path, oracle_source(tables), check),
        )
    )


def main() -> int:
    script_core = pathlib.Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--data-dir",
        type=pathlib.Path,
        help="directory containing the pinned Unicode paths (otherwise download)",
    )
    parser.add_argument(
        "--output-root",
        type=pathlib.Path,
        default=script_core,
        help="Core package root",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="verify generated files without modifying them",
    )
    arguments = parser.parse_args()

    if arguments.data_dir is not None:
        return 0 if generate(arguments.data_dir, arguments.output_root, arguments.check) else 1

    with tempfile.TemporaryDirectory(prefix="cmdy-unicode-width-") as temporary:
        data_root = pathlib.Path(temporary)
        download_inputs(data_root)
        return 0 if generate(data_root, arguments.output_root, arguments.check) else 1


if __name__ == "__main__":
    raise SystemExit(main())
