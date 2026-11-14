"""Reads back with OpenCascade, through the OCP bindings, every boolean result Locus's tests
check and the results of its solids fuzzer's plain run, as STEP (the research review's item
18; src/locus/src/boolean/step_corpus.zig writes them). Each file must load without a
message from the reader, transfer to a shape BRepCheck finds valid, and hold the faces,
solids and volume Locus says it has (its manifest line and the header's report), as
validate-step.py holds KupCAD's own exports; the volume to a part in a million, the
boolean's largest gap over the area (a vertex merged off a face's plane by its gap moves
the face a reader rebuilds by that much) and its shift (the volume its faces moved onto
their coplanar groups' planes, D28). Run `pnpm check:locus-step` from the
repository root, with the bindings installed (`pip install -r core/scripts/requirements.txt`);
with a directory argument, the files already written there are read instead of written
anew.
"""

import importlib.util
import pathlib
import re
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
LOCUS = HERE.parent / "src" / "locus"
# The tests whose results are written: every case `pipeline_test.sound` passes, and the
# solids fuzzer's plain run
FILTERS = ["corpus", "degeneracy", "boolean:", "coverage", "Fuzz solids"]
LINE = re.compile(r"^(\S+) solids=(\d+) faces=(\d+) volume=(\S+) area=(\S+) gap=(\S+) shift=(\S+) (.*)$")

# Loaded from its file (its name has a hyphen), its bytecode not written beside it
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("validate_step", HERE / "validate-step.py")
validate_step = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validate_step)


def write(directory):
    """Runs Locus's tests with the STEP corpus written to `directory`."""
    args = ["zig", "build", "test", f"-Dstep-corpus={directory}"]
    for name in FILTERS:
        args.append(f"-Dtest-filter={name}")
    result = subprocess.run(args, cwd=LOCUS, capture_output=True, text=True)
    if result.returncode != 0:
        sys.stderr.write(result.stdout + result.stderr)
        raise SystemExit("Locus's tests failed while writing the STEP corpus")


def check(directory):
    """Reads every file of the manifest in `directory`; 0 when every one is sound."""
    manifest = pathlib.Path(directory) / "manifest.txt"
    lines = manifest.read_text().splitlines()
    failed = 0
    for line in lines:
        match = LINE.match(line)
        if match is None:
            raise SystemExit(f"{manifest}: not a manifest line: {line}")
        name, solids, faces, volume, area, gap, shift, what = match.groups()
        slack = validate_step.VOLUME_TOLERANCE * float(volume) + float(gap) * float(area) + float(shift)
        found = validate_step.problems(pathlib.Path(directory) / name, int(faces), int(solids), float(volume), slack)
        if found:
            failed += 1
            print(f"{name} ({what}): {len(found)} problems", file=sys.stderr)
            for problem in found:
                print(f"  {problem}", file=sys.stderr)
    print(f"{len(lines) - failed} of {len(lines)} results read back sound")
    return 1 if failed else 0


def main():
    if len(sys.argv) > 1:
        return check(sys.argv[1])
    with tempfile.TemporaryDirectory(prefix="locus-step-") as tmp:
        write(tmp)
        return check(tmp)


if __name__ == "__main__":
    sys.exit(main())
