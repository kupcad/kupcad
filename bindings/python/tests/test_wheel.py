"""The build hook (hatch_build.py) puts the library into a wheel of its platform, with the
notices and the license texts beside it. The library is a stand-in, as the hook only carries
it (which texts they are is collect-licenses.sh's business, and whether the library runs is the
release's, installing the wheel on its system)."""

from __future__ import annotations

import os
import subprocess
import sys
import zipfile
from pathlib import Path

import pytest

pytestmark = pytest.mark.skipif(
    bool(os.environ.get("KUPCAD_INSTALLED_WHEEL")), reason="builds from the source tree"
)

PROJECT = Path(__file__).resolve().parents[1]
PLATFORM = "macosx_15_0_arm64"


@pytest.fixture
def library(tmp_path: Path) -> Path:
    """A library staged as the release stages it."""
    stage = tmp_path / "stage"
    (stage / "licenses" / "manifold").mkdir(parents=True)
    (stage / "licenses" / "manifold" / "LICENSE").write_text("Apache License\n")
    (stage / "THIRD_PARTY_NOTICES.md").write_text("# Third-party notices\n")
    path = stage / "libkupcad.dylib"
    path.write_bytes(b"a library")
    return path


def build_wheel(library: Path, platform: str, out: Path) -> subprocess.CompletedProcess[str]:
    environment = {**os.environ, "KUPCAD_LIBRARY": str(library), "KUPCAD_WHEEL_PLATFORM": platform}
    command = [sys.executable, "-m", "build", "--wheel", "--no-isolation", "--outdir", str(out)]
    return subprocess.run(
        command, cwd=PROJECT, env=environment, capture_output=True, text=True, check=False
    )


def test_the_library_and_its_notices_go_into_a_wheel_of_its_platform(
    library: Path, tmp_path: Path
) -> None:
    built = build_wheel(library, PLATFORM, tmp_path / "dist")
    assert built.returncode == 0, built.stderr
    [wheel] = (tmp_path / "dist").glob("*.whl")
    assert wheel.name.endswith(f"-py3-none-{PLATFORM}.whl")
    with zipfile.ZipFile(wheel) as archive:
        names = archive.namelist()
        info = archive.read(next(name for name in names if name.endswith(".dist-info/WHEEL")))
    assert {
        "kupcad/__init__.py",
        "kupcad/_native.py",
        "kupcad/py.typed",
        "kupcad/libkupcad.dylib",
        "kupcad/THIRD_PARTY_NOTICES.md",
        "kupcad/licenses/manifold/LICENSE",
    } <= set(names)
    assert b"Root-Is-Purelib: false" in info


def test_a_library_without_the_notices_beside_it_is_refused(library: Path, tmp_path: Path) -> None:
    (library.parent / "THIRD_PARTY_NOTICES.md").unlink()
    built = build_wheel(library, PLATFORM, tmp_path / "dist")
    assert built.returncode != 0
    assert "THIRD_PARTY_NOTICES.md not found" in built.stdout + built.stderr


def test_a_library_not_named_as_its_platforms_is_refused(library: Path, tmp_path: Path) -> None:
    built = build_wheel(library, "manylinux_2_28_x86_64", tmp_path / "dist")
    assert built.returncode != 0
    assert "isn't named libkupcad.so" in built.stdout + built.stderr
