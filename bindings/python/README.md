# KupCAD for Python

Builds the model of a [KupCAD](https://kupcad.org) script, with its parameters, as STL, 3MF,
glTF, OBJ, STEP, SVG or DXF, and formats, lints and reads the parameters of scripts. It runs
libkupcad, the KupCAD core as a C library, in your process: nothing to install besides the
package, which has no dependencies.

```sh
pip install kupcad
```

```python
from pathlib import Path

import kupcad

source = Path("bracket.kup").read_text(encoding="utf-8")
model = kupcad.build(source, format="stl", params={"width": 60, "label": "A"})
Path("bracket.stl").write_bytes(model.data)
print(model.report.output)  # what the script printed
for warning in model.report.warnings:
    print(f"{warning.line}: {warning.message}")
```

## What it does

- `kupcad.build(source, *, format, params, files, memory_limit, timeout, draco)` runs the
  script and returns a `kupcad.Model`: its `data` (bytes) in the `format` (one of
  `kupcad.FORMATS`, the library's: `stl`, `3mf`, `glb`, `gltf`, `obj`, `step`, `svg`, `dxf`),
  and the run's `report`, what the script printed and the `kupcad.RunWarning`s it warned of,
  where.
  - `params`: the parameters' values by name, as `kupcad build -p` takes them:
    `{"width": 60, "thread": "m4", "holes": [[5, 5], [35, 5]]}`. Values are checked against
    each parameter's rules.
  - `files`: the files the script imports, by their path from its folder (a `str`, or a `Path`
    by its forward slashes), text or bytes:
    `{"lib/gears.kup": Path("lib/gears.kup").read_text(encoding="utf-8"), "a.ttf": font}`. A
    script reads no other file, and its exports (`export_stl`) write nothing.
  - `memory_limit`: the most memory, in bytes, the script may hold: its values and its geometry
    graph, not the kernel's meshes; no limit by default.
  - `timeout`: the most time, in seconds, the build may take, to the millisecond; no limit by
    default (or `math.inf`). A script that never ends otherwise holds its thread for good: a
    native call can't be interrupted, by Ctrl-C or a signal.
  - `draco=True` compresses a GLB's or a glTF's meshes.
- `kupcad.format(source)`: the source as `kupcad fmt` formats it.
- `kupcad.check(source)`: what `kupcad check` finds, a list of `kupcad.Finding` (severity, rule,
  message, where, and the fix if there is one). Syntax errors are findings here.
- `kupcad.params(source)`: the parameters the script declares and its metadata, the schema
  `kupcad doc` prints, to build a form from.
- `kupcad.library_version()`: the version of libkupcad loaded.

## Errors

- `kupcad.ScriptError` (a `kupcad.Error`) when the script doesn't parse or compile, raises,
  runs past its `timeout` or `memory_limit`, or leaves no model. A value one of its parameters
  refuses is one too: the script raises `ValueError` at the `param` that refuses it. The
  message says where and why (`"2:5: Invalid expression ..."`, `"RuntimeError: Plate too
  thin"`), and its `report` holds what the script printed until then.
- `ValueError` for a format that isn't one, a limit that isn't positive, or parameter values
  JSON can't hold (NaN) or that aren't by name (a list); `TypeError` for values JSON has no type
  for (a set), or a source or a file that isn't text or bytes.
- `MemoryError` when the process itself runs out of memory, and `kupcad.Error` itself when
  libkupcad fails on its own, a bug of KupCAD's.

## Threads and processes

A build releases the GIL while it runs, so other threads go on, and builds on several threads
run at once: libkupcad's calls share nothing. A process may fork between builds (gunicorn's
`--preload`, multiprocessing's fork), whatever threads built before: the last build to end ends
the worker threads the builds started, and each process starts its own; but not while a build
runs on another thread. The core runs in your process, so a bug it stops on stops the process
too. To run scripts you don't trust, or keep a crash away from a web server, run the
[`kupcad` CLI](https://docs.kupcad.org/reference/tooling/cli/) as a process of its own.

## Platforms

Each wheel carries its libkupcad: Linux (x86_64, aarch64; glibc 2.28 or later), macOS 15 or
later (arm64, x86_64) and Windows (x64, arm64), for any Python from 3.10, with
`THIRD_PARTY_NOTICES.md` and the license texts of what it is built from beside it, in the
`kupcad` package. Elsewhere (musl, BSD), build libkupcad with `zig build lib` in the kupcad
repository's `core/` and a wheel with it, as the Development section says.

## Development

In the kupcad repository:

```sh
(cd core && zig build lib -Doptimize=safe)    # core/zig-out/lib/libkupcad.*
cd bindings/python
python -m venv .venv
.venv/bin/pip install -e . --group dev
.venv/bin/pytest                              # on the checkout's libkupcad
.venv/bin/ruff check && .venv/bin/ruff format --check && .venv/bin/mypy
```

A wheel carries the library it is built with, and the notices
`core/scripts/collect-licenses.sh <the library's folder>` (run from the repository root) puts
beside it:
`KUPCAD_LIBRARY=<library> KUPCAD_WHEEL_PLATFORM=<platform tag> python -m build --wheel`, as the
release builds one for each platform (a relative `KUPCAD_LIBRARY` is from `bindings/python/`).
