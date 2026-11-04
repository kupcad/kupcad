"""KupCAD from Python.

Build the model of a KupCAD script, with its parameters, in any format the CLI exports, and
format, lint and read the parameters of scripts. It runs libkupcad, the KupCAD core as a C
library, in the process; a script reads only the files given with it.

    model = kupcad.build(Path("bracket.kup").read_text(), format="stl", params={"width": 60})
    Path("bracket.stl").write_bytes(model.data)
"""

from __future__ import annotations

import json
import struct
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any

from . import _native
from ._version import __version__

__all__ = [
    "FORMATS",
    "Error",
    "Finding",
    "Model",
    "Report",
    "RunWarning",
    "ScriptError",
    "__version__",
    "build",
    "check",
    "format",
    "library_version",
    "params",
]

# The formats a model can be built in
FORMATS = ("stl", "3mf", "glb", "gltf", "obj", "step", "svg", "dxf")


@dataclass(frozen=True, slots=True)
class RunWarning:
    """Something the script warned of: at its line and column (1-based; None where it wasn't
    running, as the model was meshed), in `file`, the imported file whose code warned (None for
    the script's own)."""

    message: str
    line: int | None
    column: int | None
    file: str | None


@dataclass(frozen=True, slots=True)
class Report:
    """What a run printed (`puts`, `print`, `warn`), up to 64 KB (`output_cut` past them), and
    what it warned of."""

    output: str
    output_cut: bool
    warnings: tuple[RunWarning, ...]

    @classmethod
    def from_json(cls, text: str) -> Report:
        fields = json.loads(text)
        return cls(
            output=fields["output"],
            output_cut=fields["outputCut"],
            warnings=tuple(RunWarning(**warning) for warning in fields["warnings"]),
        )


@dataclass(frozen=True, slots=True)
class Model:
    """A built model: its bytes in `format`, and the run's report."""

    data: bytes
    format: str
    report: Report


@dataclass(frozen=True, slots=True)
class Finding:
    """A lint finding or a syntax error, as `kupcad check --format json` gives it: its severity
    ("error", "warning" or "info"), its rule (None for a syntax error), its code, its message,
    where it starts and ends (1-based), and its fix, if it has one."""

    severity: str
    rule: str | None
    code: str | None
    message: str
    line: int
    column: int
    end_line: int
    end_column: int
    fix: dict[str, Any] | None


class Error(Exception):
    """libkupcad failed on its own (a bug of the core's)."""


class ScriptError(Error):
    """The script doesn't parse or compile, raises, or leaves no model to export. The message
    says where and why: "2:5: Invalid expression ...", "RuntimeError: Plate too thin"."""

    def __init__(self, message: str, report: Report | None = None) -> None:
        super().__init__(message)
        # What the script printed and warned of before it failed; None when it didn't run
        self.report = report


def library_version() -> str:
    """The version of the libkupcad loaded: the package's, unless KUPCAD_LIBRARY names another."""
    version: str = json.loads(_text(_native.lib.kupcad_version()))["version"]
    return version


def format(source: str) -> str:
    """`source` formatted, as `kupcad fmt` formats it. Raises ScriptError when it doesn't parse."""
    encoded = source.encode()
    return _text(_native.lib.kupcad_format(encoded, len(encoded)))


def check(source: str) -> list[Finding]:
    """The findings of `source`: lint findings and syntax errors."""
    encoded = source.encode()
    findings = json.loads(_text(_native.lib.kupcad_check(encoded, len(encoded))))
    return [
        Finding(
            severity=finding["severity"],
            rule=finding["rule"],
            code=finding["code"],
            message=finding["message"],
            line=finding["line"],
            column=finding["column"],
            end_line=finding["endLine"],
            end_column=finding["endColumn"],
            fix=finding.get("fix"),
        )
        for finding in findings
    ]


def params(source: str) -> dict[str, Any]:
    """The parameters `source` declares and its metadata, the schema `kupcad doc` prints:
    {"meta": {"title": ...}, "parameters": [{"name": ..., "type": ..., "default": ...}]}."""
    encoded = source.encode()
    schema: dict[str, Any] = json.loads(_text(_native.lib.kupcad_params(encoded, len(encoded))))
    return schema


def build(
    source: str,
    *,
    format: str = "stl",
    params: Mapping[str, Any] | None = None,
    files: Mapping[str, str | bytes] | None = None,
    memory_limit: int | None = None,
    draco: bool = False,
) -> Model:
    """Runs `source` and builds its model in `format` (one of FORMATS).

    params: the parameters' values by name, as `kupcad build -p` takes them
        ({"width": 60, "label": "A", "holes": [[5, 5], [35, 5]]}).
    files: the files the script imports, by their path from its folder
        ({"lib/gears.kup": Path("lib/gears.kup").read_text()}).
    memory_limit: the most memory, in bytes, the script may hold; None for no limit.
    draco: compress a GLB's or a glTF's meshes with Draco.

    Raises ScriptError when the script fails, with what it printed and warned of until then,
    and ValueError for a format that isn't one or parameter values a parameter refuses.
    """
    encoded = source.encode()
    # allow_nan=False: JSON has no NaN, and a parameter would refuse it anyway
    values = json.dumps(params, allow_nan=False).encode() if params else b""
    packed = _pack(files or {})
    result = _native.lib.kupcad_build(
        encoded,
        len(encoded),
        format.encode(),
        values,
        len(values),
        packed,
        len(packed),
        memory_limit or 0,
        draco,
    )
    data, report = _take(result)
    if report is None:
        raise Error("libkupcad built the model but gave no report")
    return Model(data=data, format=format, report=Report.from_json(report))


def _text(result: int) -> str:
    return _take(result)[0].decode()


def _take(result: int) -> tuple[bytes, str | None]:
    """The data and the report of a call's result; raises what failed."""
    status, data, message, report = _native.take(result)
    if status == _native.OK:
        return data, report
    message = message or "libkupcad failed without saying why"
    if status == _native.SCRIPT_ERROR:
        raise ScriptError(message, Report.from_json(report) if report else None)
    if status == _native.INVALID_ARGUMENT:
        raise ValueError(message)
    if status == _native.OUT_OF_MEMORY:
        raise MemoryError(message)
    raise Error(message)


def _pack(files: Mapping[str, str | bytes]) -> bytes:
    """The files packed as kupcad.h describes: each its path's length, its path, its content's
    length and its content, each length 4 bytes, little-endian."""
    packed = bytearray()
    for path, content in files.items():
        for field in (path.encode(), content.encode() if isinstance(content, str) else content):
            packed += struct.pack("<I", len(field)) + field
    return bytes(packed)
