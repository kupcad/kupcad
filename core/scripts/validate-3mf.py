"""Builds models that reach every branch of the 3MF exporter (copies placed by translate and
rotate, a mirrored part, unnamed parts, colours and transparency, a title to escape, an Array
as the model, --split) with the kupcad binary, and reads each file with lib3mf, the 3MF
Consortium's library, in strict mode. Any warning, a refused file, or objects, build items or
a title other than the model's fails. Run `pnpm check:3mf` from the repository root after
`zig build`, with lib3mf installed (`pip install -r core/scripts/requirements.txt`).
"""

import pathlib
import subprocess
import sys
import tempfile

import lib3mf

KUPCAD = pathlib.Path(__file__).resolve().parent.parent / "zig-out" / "bin" / "kupcad"

# Each model, and the objects (one per part), build items (one per copy) and title its 3MF holds.
MODELS = {
    "plain": ("cube(10)", 1, 1, None),
    "copies": (
        """bolt = cylinder(r: 1, h: 6).named("M3 bolt")
left = cube(x: 4, y: 2, z: 1).named("bracket")
parts = [bolt, bolt.translate(5, 0, 0), bolt.rotate(30, 45, 60).translate(0, 7, 2), left, left.mirror(1, 0, 0), cube(1)]
assemble(name: "Pair & <spares>", parts: parts)""",
        4,
        6,
        "Pair & <spares>",
    ),
    "materials": (
        """a = cube(2).material(color: "#FF0000", metallic: 0.5)
b = sphere(1).translate(x: 5).material(color: "#00FF00", alpha: 0.5)
c = (cube(2).material(color: "#0000FF") + cube(2).translate(x: 1)).translate(y: 10)
assemble(name: "colours", parts: [a, b, c, a.translate(0, 0, 5)])""",
        3,
        4,
        "colours",
    ),
    "array": ("[cube(1), cube(1).translate(3, 0, 0), sphere(2).translate(0, 9, 0)]", 2, 3, None),
}


def read(path):
    """The model lib3mf reads from `path` in strict mode, and its warnings."""
    model = lib3mf.get_wrapper().CreateModel()
    reader = model.QueryReader("3mf")
    reader.SetStrictModeActive(True)
    reader.ReadFromFile(str(path))
    warnings = [reader.GetWarning(i) for i in range(reader.GetWarningCount())]
    return model, warnings


# A title not checked: a split part's is its name, which its file's may number ("bracket 2")
ANY_TITLE = object()


def problems(path, objects, items, title):
    """What is wrong with the 3MF file at `path`, which should hold `objects`, `items` and
    `title` (or ANY_TITLE)."""
    try:
        model, warnings = read(path)
    except lib3mf.ELib3MFException as err:
        return [f"lib3mf refused it: {err}"]
    found = [f"warning {code}: {message}" for code, message in warnings]
    if model.GetUnit() != lib3mf.ModelUnit.MilliMeter:
        found.append(f"unit {model.GetUnit()}, not millimetres")
    meshes = model.GetMeshObjects()
    count = 0
    while meshes.MoveNext():
        mesh = meshes.GetCurrentMeshObject()
        count += 1
        if mesh.GetTriangleCount() == 0:
            found.append(f"object {mesh.GetResourceID()} has no triangles")
    if count != objects:
        found.append(f"{count} objects, not {objects}")
    if model.GetBuildItems().Count() != items:
        found.append(f"{model.GetBuildItems().Count()} build items, not {items}")
    metadata = model.GetMetaDataGroup()
    titles = [metadata.GetMetaData(i).GetValue() for i in range(metadata.GetMetaDataCount()) if metadata.GetMetaData(i).GetName() == "Title"]
    if title is not ANY_TITLE and titles != ([title] if title else []):
        found.append(f"title {titles}, not {title!r}")
    return found


def build(script, *args):
    result = subprocess.run([str(KUPCAD), "build", str(script), *args], capture_output=True, text=True)
    if result.returncode != 0:
        sys.stderr.write(result.stdout + result.stderr)
        raise SystemExit(f"kupcad build {script.name} {' '.join(args)} failed")


def main():
    failed = False
    with tempfile.TemporaryDirectory(prefix="kupcad-3mf-") as tmp:
        tmp = pathlib.Path(tmp)
        for name, (source, objects, items, title) in MODELS.items():
            script = tmp / f"{name}.kup"
            script.write_text(source)
            out = tmp / f"{name}.3mf"
            build(script, "-o", str(out))
            checks = [(out.name, problems(out, objects, items, title))]
            # Each part on its own: one object, placed once, named after its part
            parts = tmp / f"{name}-parts"
            build(script, "--split", str(parts), "-f", "3mf")
            for part in sorted(parts.glob("*.3mf")):
                checks.append((f"{name} --split {part.name}", problems(part, 1, 1, ANY_TITLE)))
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
