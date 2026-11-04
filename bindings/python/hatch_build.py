"""Puts libkupcad into the wheel and tags the wheel with its platform.

KUPCAD_LIBRARY names the library, built for the platform KUPCAD_WHEEL_PLATFORM names
(manylinux_2_28_x86_64, macosx_15_0_arm64, win_amd64...), as the release builds them, with
THIRD_PARTY_NOTICES.md and the license texts of what it is built from beside it
(core/scripts/collect-licenses.sh), which go into the wheel with it. The package is Python
alone: the library is what ties a wheel to a platform, so a wheel without one isn't built.
Whether the library is built for that platform the release checks by installing the wheel there
and running the tests on it. An editable install takes none: it loads the library
KUPCAD_LIBRARY names at run time.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any

from hatchling.builders.config import BuilderConfig
from hatchling.builders.hooks.plugin.interface import BuildHookInterface


class CustomBuildHook(BuildHookInterface[BuilderConfig]):
    def initialize(self, version: str, build_data: dict[str, Any]) -> None:
        if version == "editable":
            return
        library = os.environ.get("KUPCAD_LIBRARY")
        platform = os.environ.get("KUPCAD_WHEEL_PLATFORM")
        if not library or not platform:
            raise RuntimeError(
                "a kupcad wheel carries libkupcad: set KUPCAD_LIBRARY to the library (`zig build "
                "lib` in core/) and KUPCAD_WHEEL_PLATFORM to its wheel platform tag"
            )
        path = Path(library).resolve()
        if not path.is_file():
            raise RuntimeError(f"{path} not found: build it with `zig build lib` in core/")
        name = _library_name(platform)
        if path.name != name:
            raise RuntimeError(f"{path} isn't named {name}, as kupcad loads it on {platform}")
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


def _library_name(platform: str) -> str:
    """The file name libkupcad has on `platform`, as kupcad._native loads it."""
    if platform.startswith("macosx_"):
        return "libkupcad.dylib"
    if platform.startswith("win"):
        return "kupcad.dll"
    return "libkupcad.so"
