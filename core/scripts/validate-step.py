"""Builds a model of every kind the B-Rep engine exports (a box, a cylinder, a sphere, a
cone, an extrusion with a hole, a revolution with an apex, a turned copy) with the kupcad
binary, and reads each STEP file back with OpenCascade through the OCP bindings. A file
that does not transfer to a shape, a shape its checker finds invalid, a face count other
than Locus's, a volume off the exact one, or a header whose counts (the writer's report,
in FILE_DESCRIPTION) differ from what OpenCascade finds fails. Run `pnpm check:step` from the
repository root after `zig build`, with the bindings installed (`pip install -r
core/scripts/requirements.txt`).
"""

import math
import pathlib
import re
import subprocess
import sys
import tempfile

from OCP.BRepCheck import BRepCheck_Analyzer
from OCP.BRepGProp import BRepGProp
from OCP.GProp import GProp_GProps
from OCP.IFSelect import IFSelect_RetDone
from OCP.STEPControl import STEPControl_Reader
from OCP.TopAbs import TopAbs_FACE, TopAbs_SOLID
from OCP.TopExp import TopExp_Explorer

KUPCAD = pathlib.Path(__file__).resolve().parent.parent / "zig-out" / "bin" / "kupcad"

# Each model: its script, the faces its STEP holds, and its exact volume.
PI = math.pi
MODELS = {
    "box": ("cube(2, 3, 4)", 6, 24),
    "cylinder": ("cylinder(r: 2, h: 5)", 4, PI * 4 * 5),
    "sphere": ("sphere(r: 3)", 2, 4 / 3 * PI * 27),
    "cone": ("cylinder(r1: 2, r2: 1, h: 3)", 4, PI * 3 / 3 * (4 + 2 + 1)),
    "slab": ("polygon([[0, 0], [10, 0], [10, 10], [0, 10], [2, 2], [2, 4], [4, 4], [4, 2]], paths: [[0, 1, 2, 3], [4, 5, 6, 7]]).extrude(3)", 10, 96 * 3),
    "drum": ("circle(r: 2).extrude(5)", 4, PI * 4 * 5),
    "ring": ("square(2, 3).translate(1, 0).revolve(segments: 64)", 8, PI * (9 - 1) * 3),
    "spun_cone": ("polygon([[0, 0], [2, 0], [0, 3]]).revolve(segments: 64)", 4, PI * 4 * 3 / 3),
    "moved": ("cube(2, 3, 4).translate(1, 2, 3).rotate(30, 40, 50)", 6, 24),
}
VOLUME_TOLERANCE = 1e-6


def read(path):
    """The shape OpenCascade reads from the STEP file at `path`."""
    reader = STEPControl_Reader()
    if reader.ReadFile(str(path)) != IFSelect_RetDone:
        raise ValueError("not read")
    if reader.TransferRoots() == 0:
        raise ValueError("no shape transferred")
    return reader.OneShape()


def count_of(shape, kind):
    """How many sub-shapes of `kind` the shape has."""
    count = 0
    explorer = TopExp_Explorer(shape, kind)
    while explorer.More():
        count += 1
        explorer.Next()
    return count


def reported(path):
    """The counts the writer put in the file's FILE_DESCRIPTION, by name (`faces`,
    `solids`, ...), or None when the header has none."""
    text = pathlib.Path(path).read_text()
    match = re.search(r"FILE_DESCRIPTION\(\('KupCAD B-Rep export','([^']*)'\)", text)
    if match is None:
        return None
    return {name: int(n) for n, name in re.findall(r"(\d+) (\w+)", match.group(1))}


def problems(path, faces, volume):
    """What is wrong with the STEP file at `path`, which should read as a valid shape of
    `faces` faces and `volume`."""
    try:
        shape = read(path)
    except (ValueError, RuntimeError) as err:
        return [f"OpenCascade refused it: {err}"]
    found = []
    if not BRepCheck_Analyzer(shape).IsValid():
        found.append("the shape is not valid")
    count = count_of(shape, TopAbs_FACE)
    if count != faces:
        found.append(f"{count} faces, not {faces}")
    report = reported(path)
    if report is None:
        found.append("no report in the header")
    else:
        if report.get("faces") != count:
            found.append(f"the header reports {report.get('faces')} faces, OpenCascade finds {count}")
        solids = count_of(shape, TopAbs_SOLID)
        if report.get("solids") != solids:
            found.append(f"the header reports {report.get('solids')} solids, OpenCascade finds {solids}")
    props = GProp_GProps()
    BRepGProp.VolumeProperties_s(shape, props)
    if abs(props.Mass() - volume) > VOLUME_TOLERANCE * volume:
        found.append(f"volume {props.Mass()}, not {volume}")
    return found


def build(script, *args):
    result = subprocess.run([str(KUPCAD), "build", str(script), *args], capture_output=True, text=True)
    if result.returncode != 0:
        sys.stderr.write(result.stdout + result.stderr)
        raise SystemExit(f"kupcad build {script.name} {' '.join(args)} failed")


def main():
    failed = False
    with tempfile.TemporaryDirectory(prefix="kupcad-step-") as tmp:
        tmp = pathlib.Path(tmp)
        for name, (source, faces, volume) in MODELS.items():
            script = tmp / f"{name}.kup"
            script.write_text(f"CAD.config(engine: :brep)\n{source}\n")
            out = tmp / f"{name}.step"
            build(script, "-o", str(out))
            found = problems(out, faces, volume)
            if found:
                failed = True
                print(f"{out.name}: {len(found)} problems", file=sys.stderr)
                for problem in found:
                    print(f"  {problem}", file=sys.stderr)
            else:
                print(f"{out.name}: valid")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
