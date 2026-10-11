"""The complete native compilation inputs shared by builder and verifier."""
from pathlib import Path


def native_inputs(core: Path) -> list[Path]:
    sources = [path for path in (core / "Zig").rglob("*")
               if path.is_file() and path.suffix in (".zig", ".metal")]
    sources.extend(path for path in (core / "Platform").rglob("*")
                   if path.is_file() and path.suffix in (".h", ".c", ".m"))
    data = core / "Zig/testdata"
    if data.exists():
        sources.extend(path for path in data.rglob("*") if path.is_file())
    sources.extend(path for path in (core / "Sources/CmdyNative/include").rglob("*.h")
                   if path.name != "cmdy_engine_build.h")
    sources.extend(core / "Tools/ZigEngine" / name for name in ("build.py", "source_inputs.py", "apple_toolchain.py"))
    return sorted(set(sources))
