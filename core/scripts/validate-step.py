"""Builds a model of every kind the B-Rep engine exports (a box, a cylinder, a sphere, a
cone, an extrusion with a hole, a revolution with an apex, a turned copy, and boolean
results: a corner union, a box with a void, two solids touching along an edge, a cut by a
slanted plane) with the kupcad binary, and reads each STEP file back with OpenCascade
through the OCP bindings. A file its reader had anything to say about while loading (its
check list), one that does not transfer to a shape, a shape its checker finds invalid, a
face or solid count other than Locus's, a volume off the exact one, or a header whose counts
(the writer's report, in FILE_DESCRIPTION) differ from what OpenCascade finds fails. Run `pnpm check:step` from the
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

# Each model: its script, the faces and solids its STEP holds, and its exact volume.
PI = math.pi
MODELS = {
    "box": ("cube(2, 3, 4)", 6, 1, 24),
    "cylinder": ("cylinder(r: 2, h: 5)", 4, 1, PI * 4 * 5),
    "sphere": ("sphere(r: 3)", 2, 1, 4 / 3 * PI * 27),
    "cone": ("cylinder(r1: 2, r2: 1, h: 3)", 4, 1, PI * 3 / 3 * (4 + 2 + 1)),
    "slab": ("polygon([[0, 0], [10, 0], [10, 10], [0, 10], [2, 2], [2, 4], [4, 4], [4, 2]], paths: [[0, 1, 2, 3], [4, 5, 6, 7]]).extrude(3)", 10, 1, 96 * 3),
    "drum": ("circle(r: 2).extrude(5)", 4, 1, PI * 4 * 5),
    "ring": ("square(2, 3).translate(1, 0).revolve(segments: 64)", 8, 1, PI * (9 - 1) * 3),
    "spun_cone": ("polygon([[0, 0], [2, 0], [0, 3]]).revolve(segments: 64)", 4, 1, PI * 4 * 3 / 3),
    "moved": ("cube(2, 3, 4).translate(1, 2, 3).rotate(30, 40, 50)", 6, 1, 24),
    # Two cubes overlapping at a corner: three faces of each notched, three of each whole
    "corner_union": ("cube(2, 2, 2) + cube(2, 2, 2).translate(1, 1, 1)", 12, 1, 8 + 8 - 1),
    # A cube-shaped void: one solid of two shells, the inner one facing in
    "void": ("cube(4, 4, 4) - cube(2, 2, 2).translate(1, 1, 1)", 12, 1, 64 - 8),
    # A box with a void beside a cube: written by its parts, one with its void
    "void_and_apart": ("(cube(4, 4, 4) - cube(2, 2, 2).translate(1, 1, 1)) + cube(1, 1, 1).translate(6, 0, 0)", 18, 2, 64 - 8 + 1),
    # Two cubes sharing an edge: two solids, each keeping its own copy of the edge
    "edge_touching": ("cube(1, 1, 1) + cube(1, 1, 1).translate(1, 1, 0)", 12, 2, 2),
    # The plane 2x + y + 2z = 1 (the normal 3 long, the offset along its unit) takes a
    # corner off: a tetrahedron of legs 1/2, 1, 1/2, its volume a sixth of their product
    "slanted_cut": ("cube(2, 2, 2).trim_by_plane(normal: [2, 1, 2], offset: 1.0 / 3)", 7, 1, 8 - 0.5 * 1 * 0.5 / 6),
}
VOLUME_TOLERANCE = 1e-6


def read(path):
    """The shape OpenCascade reads from the STEP file at `path`, and whether its reader's
    check list holds anything (a fail or a warning) from loading it."""
    reader = STEPControl_Reader()
    if reader.ReadFile(str(path)) != IFSelect_RetDone:
        raise ValueError("not read")
    complained = not reader.WS().ModelCheckList().IsEmpty(False)
    if reader.TransferRoots() == 0:
        raise ValueError("no shape transferred")
    return reader.OneShape(), complained


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


def problems(path, faces, solids, volume):
    """What is wrong with the STEP file at `path`, which should read as a valid shape of
    `faces` faces, `solids` solids and `volume`."""
    try:
        shape, complained = read(path)
    except (ValueError, RuntimeError) as err:
        return [f"OpenCascade refused it: {err}"]
    found = []
    if complained:
        found.append("the reader's check list is not empty (its messages are above)")
    if not BRepCheck_Analyzer(shape).IsValid():
        found.append("the shape is not valid")
    count = count_of(shape, TopAbs_FACE)
    if count != faces:
        found.append(f"{count} faces, not {faces}")
    if count_of(shape, TopAbs_SOLID) != solids:
        found.append(f"{count_of(shape, TopAbs_SOLID)} solids, not {solids}")
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
        for name, (source, faces, solids, volume) in MODELS.items():
            script = tmp / f"{name}.kup"
            script.write_text(f"CAD.config(engine: :brep)\n{source}\n")
            out = tmp / f"{name}.step"
            build(script, "-o", str(out))
            found = problems(out, faces, solids, volume)
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
