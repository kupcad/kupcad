"""libkupcad's C API, as include/kupcad.h in the kupcad repository declares it.

The library is the one KUPCAD_LIBRARY names, else the one the wheel carries beside this module.
ctypes releases the GIL while a call runs, so other threads go on; libkupcad's calls share
nothing, so they may run at once.
"""

from __future__ import annotations

import ctypes
import os
import sys
from pathlib import Path
from typing import Any

# The ABI this module declares (KUPCAD_ABI_VERSION): a library that says another is refused
ABI_VERSION = 1

LIBRARY = {"darwin": "libkupcad.dylib", "win32": "kupcad.dll"}.get(sys.platform, "libkupcad.so")

# kupcad_status
OK = 0
SCRIPT_ERROR = 1
INVALID_ARGUMENT = 2
OUT_OF_MEMORY = 3


class Result(ctypes.c_void_p):
    """A call's result (kupcad_result *), which take() reads and frees. ctypes makes it in C as
    the call returns, so nothing runs before it holds the result: an exception raised before
    take() (a Ctrl-C that came during the call, raised as it returns) drops it, and it frees the
    result as it goes, where a plain int lost it."""

    def __del__(self) -> None:
        free(self)


def free(result: Result) -> None:
    """Frees `result`, once: its pointer is cleared first, so an exception that comes between
    the two can't have it freed again."""
    pointer, result.value = result.value, None
    if pointer:
        lib.kupcad_result_free(pointer)


def _load() -> ctypes.CDLL:
    path = os.environ.get("KUPCAD_LIBRARY") or str(Path(__file__).with_name(LIBRARY))
    if not os.path.isfile(path):
        raise ImportError(
            f"{path} not found: this kupcad came without libkupcad, which only a wheel carries "
            f"(this is {sys.platform}). Set KUPCAD_LIBRARY to a libkupcad you built (`zig build "
            "lib` in the kupcad repository's core/), or run the kupcad CLI."
        )
    lib = ctypes.CDLL(path)
    # First, so a library of another ABI is refused as one, not for a function it lacks
    lib.kupcad_abi_version.argtypes = []
    lib.kupcad_abi_version.restype = ctypes.c_uint32
    abi = lib.kupcad_abi_version()
    if abi != ABI_VERSION:
        raise ImportError(
            f"{path} is libkupcad of ABI {abi}; this package speaks ABI {ABI_VERSION}: use the "
            "libkupcad of its own KupCAD version"
        )
    text = [ctypes.c_char_p, ctypes.c_size_t]
    # Each function's argument and result types, as kupcad.h declares them
    declarations: dict[str, tuple[list[Any], Any]] = {
        "kupcad_version": ([], Result),
        "kupcad_format": (text, Result),
        "kupcad_check": (text, Result),
        "kupcad_params": (text, Result),
        "kupcad_build": (
            [*text, ctypes.c_char_p, *text, *text, ctypes.c_uint64, ctypes.c_uint64, ctypes.c_bool],
            Result,
        ),
        "kupcad_result_status": ([ctypes.c_void_p], ctypes.c_int),
        "kupcad_result_data": (
            [ctypes.c_void_p, ctypes.POINTER(ctypes.c_size_t)],
            ctypes.c_void_p,
        ),
        "kupcad_result_message": (
            [ctypes.c_void_p, ctypes.POINTER(ctypes.c_size_t)],
            ctypes.c_void_p,
        ),
        "kupcad_result_report": ([ctypes.c_void_p], ctypes.c_char_p),
        "kupcad_result_free": ([ctypes.c_void_p], None),
    }
    for name, (arguments, result) in declarations.items():
        function = getattr(lib, name)
        function.argtypes = arguments
        function.restype = result
    return lib


lib = _load()


def take(result: Result) -> tuple[int, bytes, str | None, str | None]:
    """What a call gave, read and freed: its status, data, message and report. The data and the
    message are read by their length: a message can quote a NUL (the report is JSON, which
    escapes one)."""
    try:
        length = ctypes.c_size_t()
        data = _bytes_at(lib.kupcad_result_data(result, ctypes.byref(length)), length.value)
        pointer = lib.kupcad_result_message(result, ctypes.byref(length))
        message = _bytes_at(pointer, length.value).decode() if pointer else None
        report = lib.kupcad_result_report(result)
        return (
            lib.kupcad_result_status(result),
            data,
            message,
            report.decode() if report is not None else None,
        )
    finally:
        free(result)


def _bytes_at(pointer: int | None, length: int) -> bytes:
    """The `length` bytes at `pointer`, copied. ctypes.string_at takes the length as a C int,
    which a model past 2 GiB overflows."""
    if not length or pointer is None:
        return b""
    return (ctypes.c_char * length).from_address(pointer).raw
