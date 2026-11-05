"""The tests run against the kupcad package installed: the checkout's, installed editable, with
the checkout's libkupcad (`zig build lib` in core/) unless KUPCAD_LIBRARY names another; or a
wheel, on CI (KUPCAD_INSTALLED_WHEEL=1), with the library it carries."""

from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[3]
# The examples that are drawings, which build as SVG
DRAWINGS = {"cup.kup"}

if not os.environ.get("KUPCAD_INSTALLED_WHEEL"):
    # By the name kupcad._native.LIBRARY gives it, which can't be read from there: importing any
    # of kupcad runs its __init__, which loads the library this chooses
    library = {"darwin": "libkupcad.dylib", "win32": "kupcad.dll"}.get(sys.platform, "libkupcad.so")
    os.environ.setdefault("KUPCAD_LIBRARY", str(ROOT / "core" / "zig-out" / "lib" / library))


@pytest.fixture
def examples() -> list[tuple[Path, str]]:
    """The repository's example scripts, each with the format it builds in."""
    return [
        (path, "svg" if path.name in DRAWINGS else "glb")
        for path in sorted((ROOT / "examples").glob("*.kup"))
    ]
