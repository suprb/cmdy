#!/usr/bin/env python3
"""Report active terminal-stack line provenance from Git history.

This is an inventory aid, not a legal or clean-room certification. It uses
Git's move/copy-aware blame to distinguish lines attributed to the initial
vendored SwiftTerm import, lines changed while still under that vendor path,
and later history that needs human review.
"""

from __future__ import annotations

import argparse
import dataclasses
import re
import subprocess
import sys
from pathlib import Path


DEFAULT_IMPORT = "512b859268662b8e01f5923fabd7958e12e280df"

# New name first, pre-rebrand alias second. The first path present at --ref wins.
CANDIDATES: tuple[tuple[str, ...], ...] = (
    ("Core/Sources/CmdyPTY/Pty.swift", "Core/Sources/TermitePTY/Pty.swift"),
    ("Core/Sources/CmdyPTY/LocalProcess.swift", "Core/Sources/TermitePTY/LocalProcess.swift"),
    ("Core/Sources/CmdyCore/UnicodeWidth.swift", "Core/Sources/TermiteCore/UnicodeWidth.swift"),
    ("Renderer/Sources/CmdyGPU/BlockElementRenderer.swift", "Renderer/Sources/TermiteGPU/BlockElementRenderer.swift"),
    ("Renderer/Sources/CmdyGPU/BoxDrawingRenderer.swift", "Renderer/Sources/TermiteGPU/BoxDrawingRenderer.swift"),
    ("Renderer/Sources/CmdyGPU/CoreTextGlyphRasterizer.swift", "Renderer/Sources/TermiteGPU/CoreTextGlyphRasterizer.swift"),
    ("Renderer/Sources/CmdyGPU/GlyphAtlas.swift", "Renderer/Sources/TermiteGPU/GlyphAtlas.swift"),
    ("Renderer/Sources/CmdyGPU/MetalBufferingMode.swift", "Renderer/Sources/TermiteGPU/MetalBufferingMode.swift"),
    ("Renderer/Sources/CmdyGPU/MetalError.swift", "Renderer/Sources/TermiteGPU/MetalError.swift"),
    ("Renderer/Sources/CmdyGPU/MetalRenderSource.swift", "Renderer/Sources/TermiteGPU/MetalRenderSource.swift"),
    ("Renderer/Sources/CmdyGPU/MetalTerminalRenderer.swift", "Renderer/Sources/TermiteGPU/MetalTerminalRenderer.swift"),
    ("Renderer/Sources/CmdyGPU/PlatformCompat.swift", "Renderer/Sources/TermiteGPU/PlatformCompat.swift"),
    ("Renderer/Sources/CmdyGPU/RenderTypes.swift", "Renderer/Sources/TermiteGPU/RenderTypes.swift"),
    ("Renderer/Sources/CmdyGPU/Shaders.metal", "Renderer/Sources/TermiteGPU/Shaders.metal"),
    ("Renderer/Sources/CmdyGPU/CursorGlide.swift", "Renderer/Sources/TermiteGPU/CursorGlide.swift"),
    ("Renderer/Sources/CmdyGPU/DynamicBufferRing.swift", "Renderer/Sources/TermiteGPU/DynamicBufferRing.swift"),
    ("Renderer/Sources/CmdyGPU/TerminalFontFeatures.swift", "Renderer/Sources/TermiteGPU/TerminalFontFeatures.swift"),
    ("App/CmdyCoreShaping.swift", "App/TermiteCoreShaping.swift"),
    ("App/CmdyCoreSurface.swift", "App/TermiteCoreSurface.swift"),
)

# These whole files were introduced after renderer extraction and have no known
# direct vendored-file ancestor. This label is engineering evidence only.
CLEAR_CMDY_ADDITIONS = {
    "Renderer/Sources/CmdyGPU/CursorGlide.swift",
    "Renderer/Sources/TermiteGPU/CursorGlide.swift",
    "Renderer/Sources/CmdyGPU/DynamicBufferRing.swift",
    "Renderer/Sources/TermiteGPU/DynamicBufferRing.swift",
    "Renderer/Sources/CmdyGPU/TerminalFontFeatures.swift",
    "Renderer/Sources/TermiteGPU/TerminalFontFeatures.swift",
}

HEADER_RE = re.compile(r"^([0-9a-f^]{40}) \d+ (\d+)(?: \d+)?$")
SWIFT_DECL_RE = re.compile(
    r"^\s*(?:(?:public|private|fileprivate|internal|open|final|static|class|"
    r"override|required|convenience|mutating|nonmutating|nonisolated)\s+)*"
    r"(?:class|struct|enum|protocol|extension|func|init|deinit|subscript)\b.*"
)
METAL_DECL_RE = re.compile(
    r"^\s*(?:(?:vertex|fragment|kernel|static|inline)\s+)*(?:struct|[A-Za-z_]\w*(?:<[^>]+>)?)"
    r"(?:\s+|\s*\*\s*)([A-Za-z_]\w*)\s*(?:\(|\{)"
)


@dataclasses.dataclass(frozen=True)
class Line:
    number: int
    commit: str
    historical_path: str
    classification: str
    symbol: str


@dataclasses.dataclass(frozen=True)
class Region:
    start: int
    end: int
    commits: tuple[str, ...]
    historical_paths: tuple[str, ...]
    classification: str
    symbol: str


def git(*args: str, check: bool = True) -> str:
    result = subprocess.run(
        ["git", *args], check=False, text=True, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if check and result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "git command failed")
    return result.stdout


def resolve_path(ref: str, aliases: tuple[str, ...]) -> str | None:
    for path in aliases:
        result = subprocess.run(
            ["git", "cat-file", "-e", f"{ref}:{path}"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        if result.returncode == 0:
            return path
    return None


def source_lines(ref: str, path: str) -> list[str]:
    return git("show", f"{ref}:{path}").splitlines()


def symbols_for(lines: list[str], suffix: str) -> list[str]:
    symbol = "file scope"
    result: list[str] = []
    for text in lines:
        stripped = text.strip()
        if suffix == ".metal":
            match = METAL_DECL_RE.match(text)
            if match:
                symbol = match.group(1)
        elif SWIFT_DECL_RE.match(text):
            symbol = re.sub(r"\s+", " ", stripped)
            if len(symbol) > 96:
                symbol = symbol[:93] + "..."
        result.append(symbol)
    return result


def classify(commit: str, historical_path: str, current_path: str,
             import_commit: str) -> str:
    if historical_path.startswith("Vendor/SwiftTerm/"):
        if commit.lstrip("^") == import_commit:
            return "confirmed-derived"
        return "vendor-era-uncertain"
    if current_path in CLEAR_CMDY_ADDITIONS:
        return "cmdy-addition"
    return "post-extraction-review"


def blame(ref: str, path: str, import_commit: str) -> list[Line]:
    content = source_lines(ref, path)
    symbols = symbols_for(content, Path(path).suffix)
    raw = git("blame", "--line-porcelain", "-C", "-C", "-M", ref, "--", path)
    records: list[Line] = []
    commit = ""
    target_line = 0
    historical_path = path
    for item in raw.splitlines():
        header = HEADER_RE.match(item)
        if header:
            commit = header.group(1)
            target_line = int(header.group(2))
            historical_path = path
            continue
        if item.startswith("filename "):
            historical_path = item[len("filename "):]
            continue
        if item.startswith("\t"):
            if not 1 <= target_line <= len(symbols):
                raise RuntimeError(f"invalid blame line {target_line} for {path}")
            records.append(Line(
                number=target_line,
                commit=commit,
                historical_path=historical_path,
                classification=classify(commit, historical_path, path, import_commit),
                symbol=symbols[target_line - 1],
            ))
    if len(records) != len(content):
        raise RuntimeError(
            f"blame/source mismatch for {path}: {len(records)} vs {len(content)}")
    return records


def regions(lines: list[Line]) -> list[Region]:
    result: list[Region] = []
    for line in lines:
        if result:
            previous = result[-1]
            same = (
                previous.end + 1 == line.number
                and previous.classification == line.classification
                and previous.symbol == line.symbol
            )
            if same:
                commits = previous.commits
                if line.commit not in commits:
                    commits += (line.commit,)
                paths = previous.historical_paths
                if line.historical_path not in paths:
                    paths += (line.historical_path,)
                result[-1] = dataclasses.replace(
                    previous, end=line.number, commits=commits,
                    historical_paths=paths)
                continue
        result.append(Region(
            start=line.number,
            end=line.number,
            commits=(line.commit,),
            historical_paths=(line.historical_path,),
            classification=line.classification,
            symbol=line.symbol,
        ))
    return result


def markdown(ref: str, import_commit: str,
             reports: list[tuple[str, list[Line], list[Region]]],
             missing: list[tuple[str, ...]]) -> str:
    counts: dict[str, int] = {}
    for _, lines, _ in reports:
        for line in lines:
            counts[line.classification] = counts.get(line.classification, 0) + 1

    out = [
        "# Move/copy-aware terminal lineage report",
        "",
        f"- ref: `{git('rev-parse', ref).strip()}`",
        f"- initial vendor import: `{import_commit}`",
        "- method: `git blame --line-porcelain -C -C -M`",
        "- warning: classifications are audit leads, not legal conclusions",
        "",
        "## Totals",
        "",
        "| Classification | Lines |",
        "| --- | ---: |",
    ]
    for name in (
        "confirmed-derived", "vendor-era-uncertain", "cmdy-addition",
        "post-extraction-review",
    ):
        out.append(f"| {name} | {counts.get(name, 0)} |")

    if missing:
        out.extend(["", "## Missing candidates", ""])
        out.extend(f"- `{'` or `'.join(paths)}`" for paths in missing)

    for path, _, grouped in reports:
        out.extend([
            "",
            f"## `{path}`",
            "",
            "| Lines | Class | Commit | Historical path | Nearest declaration |",
            "| ---: | --- | --- | --- | --- |",
        ])
        for region in grouped:
            span = str(region.start) if region.start == region.end else f"{region.start}-{region.end}"
            symbol = region.symbol.replace("|", "\\|").replace("`", "'")
            history = "<br>".join(
                f"`{path.replace('|', '\\|')}`" for path in region.historical_paths)
            commits = ", ".join(f"`{commit[:12]}`" for commit in region.commits)
            out.append(
                f"| {span} | {region.classification} | {commits} | "
                f"{history} | {symbol} |"
            )
    return "\n".join(out) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ref", default="HEAD", help="Git revision to inventory")
    parser.add_argument("--import-ref", default=DEFAULT_IMPORT,
                        help="commit that introduced Vendor/SwiftTerm")
    parser.add_argument("--output", help="write Markdown report to this path")
    args = parser.parse_args()

    try:
        import_commit = git("rev-parse", args.import_ref).strip()
        reports: list[tuple[str, list[Line], list[Region]]] = []
        missing: list[tuple[str, ...]] = []
        for aliases in CANDIDATES:
            path = resolve_path(args.ref, aliases)
            if path is None:
                missing.append(aliases)
                continue
            lines = blame(args.ref, path, import_commit)
            reports.append((path, lines, regions(lines)))
        report = markdown(args.ref, import_commit, reports, missing)
    except (RuntimeError, subprocess.SubprocessError) as error:
        print(f"lineage audit failed: {error}", file=sys.stderr)
        return 1

    if args.output:
        Path(args.output).write_text(report, encoding="utf-8")
    else:
        sys.stdout.write(report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
