"""Builds models that reach every branch of the 2D exporters (a sketch with holes, names and
colours, Solids projected beside sketches, copies, --split) with the kupcad binary, and reads
each SVG back as XML (well-formed, in millimetres, a path per shape) and each DXF with ezdxf's
recovering reader and auditor (any error or fix fails, and each contour must be a closed
polyline on its layer). Run `pnpm check:drawings` from the repository root after `zig build`,
with ezdxf installed (`pip install -r core/scripts/requirements.txt`).
"""

import pathlib
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

import ezdxf
from ezdxf import recover

KUPCAD = pathlib.Path(__file__).resolve().parent.parent / "zig-out" / "bin" / "kupcad"
SVG_NS = "{http://www.w3.org/2000/svg}"

# Each model, with the shapes (paths, or DXF layers besides `0`) and contours its drawing holds.
MODELS = {
    "plain": ("square(10)", 1, 1),
    "holes": (
        """plate = (square(30, center: true) - circle(r: 4) - circle(r: 2).translate(x: 10)).named("plate").material(color: "#FF8800", alpha: 0.5)
[plate, circle(r: 3, segments: 6).translate(y: 30).named("hex & <6>")]""",
        2,
        4,
    ),
    "arcs": (
        """ring = circle(r: 10) - circle(r: 4).translate(x: 2)
[ring.named("ring"), square(20, round_r: 3).translate(x: 30), circle(r: 2, segments: 5).translate(y: 30)]""",
        3,
        4,
    ),
    "paths": (
        """hook = line([0, 0], [10, 0]) + arc(center: [10, 5], r: 5, start: -90, sweep: 180) + polyline([[10, 10], [0, 10]])
[hook.named("outline").material(color: "#00AA00"), hook.close.translate(y: 20), hook.stroke(1).translate(y: 40)]""",
        3,
        3,
    ),
    "mixed": (
        """lid = cube(4).named("lid").material(color: "#0000FF")
[square(5).translate(x: 20), lid, lid.translate(z: 10), cylinder(r: 3, h: 2).translate(x: 10)]""",
        4,
        4,
    ),
}


def svg_problems(path, shapes, contours):
    """What is wrong with the SVG at `path`, which should hold `shapes` paths of `contours`
    contours in all."""
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError as err:
        return [f"not well-formed XML: {err}"]
    found = []
    if root.tag != f"{SVG_NS}svg":
        found.append(f"root is {root.tag}, not svg")
    for attr in ("width", "height"):
        if not root.get(attr, "").endswith("mm"):
            found.append(f"{attr} {root.get(attr)!r} isn't in mm")
    if len(root.get("viewBox", "").split()) != 4:
        found.append(f"viewBox {root.get('viewBox')!r} isn't four numbers")
    paths = root.findall(f"{SVG_NS}path")
    if len(paths) != shapes:
        found.append(f"{len(paths)} paths, not {shapes}")
    # An open path (a Path's) has no Z and no fill; a closed one counts by its Z
    closed = sum(p.get("d", "").count(" Z") for p in paths)
    open_paths = sum(1 for p in paths if " Z" not in p.get("d", ""))
    if closed + open_paths != contours:
        found.append(f"{closed} closed and {open_paths} open subpaths, not {contours}")
    for p in paths:
        if " Z" not in p.get("d", "") and p.get("fill") != "none":
            found.append("an open path is filled")
    for p in paths:
        if p.get("fill-rule") != "evenodd":
            found.append("a path isn't filled by the even-odd rule")
        if not p.get("d", "").startswith("M "):
            found.append("a path's data doesn't start with a move")
    return found


def dxf_problems(path, shapes, contours):
    """What is wrong with the DXF at `path`, which should hold `contours` closed polylines on
    the layers of `shapes` named shapes (unnamed ones on `0`)."""
    try:
        doc, auditor = recover.readfile(str(path))
    except (IOError, ezdxf.DXFStructureError) as err:
        return [f"ezdxf refused it: {err}"]
    found = [f"audit error {e.code}: {e.message}" for e in auditor.errors]
    found += [f"audit fix {f.code}: {f.message}" for f in auditor.fixes]
    if doc.header.get("$INSUNITS") != 4:
        found.append(f"$INSUNITS {doc.header.get('$INSUNITS')}, not 4 (millimetres)")
    entities = list(doc.modelspace())
    if len(entities) != contours:
        found.append(f"{len(entities)} entities, not {contours}")
    for e in entities:
        if e.dxftype() != "LWPOLYLINE":
            found.append(f"a {e.dxftype()}, not an LWPOLYLINE")
        elif not e.closed and e.dxf.layer == "0":
            found.append("an open polyline that isn't a Path's (a Path is named here)")
        elif e.dxf.layer not in doc.layers:
            found.append(f"layer {e.dxf.layer!r} isn't in the layer table")
    named = {l.dxf.name for l in doc.layers} - {"0", "Defpoints"}
    if len(named) > shapes:
        found.append(f"{len(named)} named layers for {shapes} shapes")
    return found


def build(script, *args):
    result = subprocess.run([str(KUPCAD), "build", str(script), *args], capture_output=True, text=True)
    if result.returncode != 0:
        sys.stderr.write(result.stdout + result.stderr)
        raise SystemExit(f"kupcad build {script.name} {' '.join(args)} failed")


def main():
    failed = False
    with tempfile.TemporaryDirectory(prefix="kupcad-drawings-") as tmp:
        tmp = pathlib.Path(tmp)
        for name, (source, shapes, contours) in MODELS.items():
            script = tmp / f"{name}.kup"
            script.write_text(source)
            checks = []
            for ext, problems in (("svg", svg_problems), ("dxf", dxf_problems)):
                out = tmp / f"{name}.{ext}"
                build(script, "-o", str(out))
                checks.append((out.name, problems(out, shapes, contours)))
            # Each Solid on its own, projected: one shape
            parts = tmp / f"{name}-parts"
            build(script, "--split", str(parts), "-f", "dxf")
            for part in sorted(parts.glob("*.dxf")):
                doc = ezdxf.readfile(str(part))
                checks.append((f"{name} --split {part.name}", dxf_problems(part, 1, len(list(doc.modelspace())))))
            for label, found in checks:
                if found:
                    failed = True
                    print(f"{label}: {len(found)} problems", file=sys.stderr)
                    for problem in found:
                        print(f"  {problem}", file=sys.stderr)
                else:
                    print(f"{label}: valid")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
