"""Puts libkupcad into the wheel and tags the wheel with its platform.

KUPCAD_LIBRARY names the library, built for the platform KUPCAD_WHEEL_PLATFORM names
(manylinux_2_28_x86_64, macosx_15_0_arm64, win_amd64...), as the release builds them, with
THIRD_PARTY_NOTICES.md and the license texts of what it is built from beside it
(core/scripts/collect-licenses.sh), which go into the wheel with it. The package is Python
alone: the library is what ties a wheel to a platform, so a wheel without one isn't built. An
editable install takes none: it loads the library KUPCAD_LIBRARY names at run time.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any

from hatchling.builders.config import BuilderConfig
from hatchling.builders.hooks.plugin.interface import BuildHookInterface

# A platform tag's CPU => the CPU a library's header says
CPUS = {"x86_64": "x86_64", "amd64": "x86_64", "aarch64": "aarch64", "arm64": "aarch64"}
ELF_MACHINES = {0x3E: "x86_64", 0xB7: "aarch64"}
MACHO_CPU_TYPES = {0x01000007: "x86_64", 0x0100000C: "aarch64"}
PE_MACHINES = {0x8664: "x86_64", 0xAA64: "aarch64"}


def binary_format(path: Path) -> tuple[str, str | None] | None:
    """("elf", "macho" or "pe", and its CPU) from a 64-bit library's header; None for others."""
    header = path.read_bytes()[:64]
    if len(header) < 64:
        return None
    if header.startswith(b"\x7fELF"):
        return "elf", ELF_MACHINES.get(int.from_bytes(header[18:20], "little"))
    if header.startswith(b"\xcf\xfa\xed\xfe"):
        return "macho", MACHO_CPU_TYPES.get(int.from_bytes(header[4:8], "little"))
    if header.startswith(b"MZ"):
        offset = int.from_bytes(header[0x3C:0x40], "little")
        pe = path.read_bytes()[offset : offset + 6]
        if pe.startswith(b"PE\0\0"):
            return "pe", PE_MACHINES.get(int.from_bytes(pe[4:6], "little"))
    return None


def expected_format(platform: str) -> tuple[str, str | None]:
    """The binary format and CPU a library for the wheel platform tag `platform` has."""
    kind = (
        "macho" if platform.startswith("macosx") else "pe" if platform.startswith("win") else "elf"
    )
    return kind, CPUS.get(platform.rsplit("_", 1)[-1])


class CustomBuildHook(BuildHookInterface[BuilderConfig]):
    def initialize(self, version: str, build_data: dict[str, Any]) -> None:
        if self.target_name != "wheel" or version == "editable":
            return
        library = os.environ.get("KUPCAD_LIBRARY")
        platform = os.environ.get("KUPCAD_WHEEL_PLATFORM")
        if not library or not platform:
            raise RuntimeError(
                "a kupcad wheel carries libkupcad: set KUPCAD_LIBRARY to the library (`zig build "
                "lib` in core/) and KUPCAD_WHEEL_PLATFORM to its wheel platform tag"
            )
        path = Path(library)
        actual = binary_format(path) if path.is_file() else None
        expected = expected_format(platform)
        if actual != expected:
            raise RuntimeError(
                f"{library} is {actual or 'not a library'}, not {expected} for {platform}"
            )
        notices = path.parent / "THIRD_PARTY_NOTICES.md"
        if not notices.is_file():
            raise RuntimeError(
                f"{notices} not found: collect-licenses.sh puts it beside the library"
            )
        build_data["force_include"][str(path)] = f"kupcad/{path.name}"
        build_data["force_include"][str(notices)] = f"kupcad/{notices.name}"
        build_data["force_include"][str(path.parent / "licenses")] = "kupcad/licenses"
        build_data["pure_python"] = False
        build_data["tag"] = f"py3-none-{platform}"
