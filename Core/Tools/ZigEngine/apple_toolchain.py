"""Apple framework boundary used by the native font and Metal implementation."""
import hashlib
from pathlib import Path
import subprocess

FRAMEWORKS = ("AppKit", "Foundation", "CoreFoundation", "CoreGraphics", "CoreText",
              "Metal", "MetalKit", "QuartzCore", "ImageIO")


def apple_toolchain() -> dict:
    sdk = Path(subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip())
    clang = Path(subprocess.check_output(["xcrun", "--find", "clang"], text=True).strip()).resolve()
    settings = sdk / "SDKSettings.json"
    return {"sdk_path": str(sdk), "sdk_settings_sha256": hashlib.sha256(settings.read_bytes()).hexdigest(),
            "clang_path": str(clang), "clang_sha256": hashlib.sha256(clang.read_bytes()).hexdigest(),
            "clang_version": subprocess.check_output([str(clang), "--version"], text=True).strip()}


def zig_platform_flags(toolchain: dict, include: Path, platform: Path) -> list[str]:
    sdk = Path(toolchain["sdk_path"])
    return ["--sysroot", str(sdk), "-F" + str(sdk / "System/Library/Frameworks"),
            # Zig resolves library search directories underneath --sysroot.
            "-L/usr/lib",
            "-isystem", str(sdk / "usr/include"), "-I" + str(include), "-I" + str(platform)]


def platform_link_flags() -> list[str]:
    return [argument for framework in FRAMEWORKS for argument in ("-framework", framework)] + ["-lobjc"]
