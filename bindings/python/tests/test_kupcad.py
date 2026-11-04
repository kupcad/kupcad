from __future__ import annotations

import math
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from types import MappingProxyType

import pytest

import kupcad

FOREVER = "while true\nend\ncube(1)"


def test_the_library_is_the_package_version() -> None:
    assert kupcad.library_version() == kupcad.__version__


def test_the_formats_are_the_librarys() -> None:
    assert {"stl", "3mf", "glb", "step", "svg"} <= set(kupcad.FORMATS)


def test_build_builds_the_model_in_every_format() -> None:
    for format in kupcad.FORMATS:
        model = kupcad.build("cube(10)", format=format)
        assert model.format == format
        assert model.data


def test_build_takes_the_parameters_by_name_and_keeps_what_the_script_prints() -> None:
    source = """width = param(:width, default: 5)
thread = param(:thread, default: :m3, validate: { in: [:m3, :m4] })
holes = param(:holes, default: [[0, 0]])
puts width, thread, holes[1][0]
cube(width)"""
    values = MappingProxyType({"width": 20, "thread": "m4", "holes": [[5, 5], [35, 5]]})
    model = kupcad.build(source, params=values)
    assert model.report.output == "20\nm4\n35\n"


def test_a_value_a_parameter_refuses_fails_the_script_saying_which() -> None:
    source = "width = param(:width, default: 5, validate: { min: 1 })\ncube(width)"
    with pytest.raises(kupcad.ScriptError, match=r"^ValueError: .*width"):
        kupcad.build(source, params={"width": 0})


def test_build_reads_the_files_given_with_it_text_and_bytes() -> None:
    block = kupcad.build("cube(2)").data
    source = """import { side } from "./lib/sizes.kup"
block = import_stl("parts/block.stl")
puts side, block.volume
block + cube(side)"""
    # A Path by its forward slashes, whatever the system writes it with
    files: dict[str | Path, str | bytes] = {
        "lib/sizes.kup": "def side = 12\nexport side",
        Path("parts") / "block.stl": block,
    }
    assert kupcad.build(source, files=files).report.output == "12\n8\n"


def test_build_reports_what_the_script_warned_of_where_and_in_which_file() -> None:
    files = {"lib/walls.kup": 'def wall\n  warn("thin wall")\n  cube(1)\nend\nexport wall'}
    model = kupcad.build(
        'import { wall } from "./lib/walls.kup"\nwarn("mine")\nwall()', files=files
    )
    assert model.report.warnings == (
        kupcad.RunWarning(message="mine", line=2, column=1, file=None),
        kupcad.RunWarning(message="thin wall", line=2, column=3, file="lib/walls.kup"),
    )


def test_build_keeps_the_start_of_what_a_script_prints_past_64_kb_and_says_so() -> None:
    report = kupcad.build('(1..10000).each { |i| puts "line #{i}" }\ncube(1)').report
    assert report.output_cut
    assert report.output.startswith("line 1\nline 2\n")


def test_build_compresses_the_meshes_with_draco_when_asked() -> None:
    model = kupcad.build("sphere(r: 5)", format="glb", draco=True)
    assert b"KHR_draco_mesh_compression" in model.data


def test_a_script_that_fails_raises_where_with_what_it_printed_until_then() -> None:
    with pytest.raises(kupcad.ScriptError, match=r"^RuntimeError: Plate too thin$") as failure:
        kupcad.build('puts "before"\nraise "Plate too thin"')
    assert failure.value.report is not None
    assert failure.value.report.output == "before\n"
    with pytest.raises(kupcad.ScriptError, match=r"^2:5: "):
        kupcad.build("x = 1\ny = )")


def test_a_message_keeps_a_nul_it_quotes() -> None:
    with pytest.raises(kupcad.ScriptError) as failure:
        kupcad.build('raise "a\\0b"')
    assert str(failure.value) == "RuntimeError: a\0b"


def test_arguments_a_build_refuses_are_value_errors() -> None:
    with pytest.raises(ValueError, match="'stp' isn't a format"):
        kupcad.build("cube(1)", format="stp")
    with pytest.raises(ValueError, match="isn't a format"):
        kupcad.build("cube(1)", format="stl\0")
    with pytest.raises(ValueError, match="JSON"):
        kupcad.build("cube(1)", params={"width": math.nan})
    with pytest.raises(TypeError):
        kupcad.build("cube(1)", params={"widths": {1, 2}})
    # Values not by name, refused by the library itself
    with pytest.raises(ValueError, match="object"):
        kupcad.build("cube(1)", params=[["width", 1]])  # type: ignore[arg-type]


def test_a_limit_that_is_not_a_positive_number_is_a_value_error() -> None:
    for memory_limit in (-1, 1.5):
        with pytest.raises(ValueError, match="memory_limit"):
            kupcad.build("cube(1)", memory_limit=memory_limit)  # type: ignore[arg-type]
    for timeout in (0, math.nan, complex(1, 0)):
        with pytest.raises(ValueError, match="timeout"):
            kupcad.build("cube(1)", timeout=timeout)  # type: ignore[arg-type]


def test_a_limit_past_what_the_library_holds_is_none() -> None:
    assert kupcad.build("cube(1)", timeout=math.inf).data
    assert kupcad.build("cube(1)", timeout=10**30).data
    assert kupcad.build("cube(1)", memory_limit=2**70).data


def test_a_source_or_a_file_that_is_not_text_or_bytes_is_a_type_error() -> None:
    with pytest.raises(TypeError, match="source is NoneType"):
        kupcad.build(None)  # type: ignore[arg-type]
    with pytest.raises(TypeError, match="source is bytes"):
        kupcad.format(b"cube(1)")  # type: ignore[arg-type]
    with pytest.raises(TypeError, match=r"a\.kup is PosixPath|a\.kup is WindowsPath"):
        kupcad.build("cube(1)", files={"a.kup": Path("a.kup")})  # type: ignore[dict-item]
    with pytest.raises(TypeError, match="1 is int"):
        kupcad.build("cube(1)", files={1: "cube(1)"})  # type: ignore[type-var]


class _Huge(bytes):
    """Bytes that say they are 4 GiB long, which no test can afford to be."""

    def __len__(self) -> int:
        return 2**32


def test_a_file_past_4_gib_the_most_its_length_holds_is_a_value_error() -> None:
    with pytest.raises(ValueError, match=r"big\.kup is past 4 GiB"):
        kupcad.build("cube(1)", files={"big.kup": _Huge(b"cube(1)")})


def test_the_memory_limit_stops_a_script_that_holds_more_however_small() -> None:
    for limit in (1_000_000, 1):
        with pytest.raises(kupcad.ScriptError, match=r"^OutOfMemoryError: "):
            kupcad.build("a = (1..2_000_000).to_a\ncube(1)", memory_limit=limit)


def test_the_timeout_stops_a_script_that_never_ends() -> None:
    with pytest.raises(kupcad.ScriptError, match=r"^Time limit: the run took longer than 100 ms"):
        kupcad.build(FOREVER, timeout=0.1)
    # Rounded to whole milliseconds, so a float's error can't add one (2.007 s is
    # 2007.0000000000002 ms)
    with pytest.raises(kupcad.ScriptError, match=" 14 ms"):
        kupcad.build(FOREVER, timeout=0.0141)


def test_other_threads_run_while_it_builds() -> None:
    ticks: list[float] = []
    building = True

    def tick() -> None:
        while building:
            ticks.append(time.monotonic())
            time.sleep(0.01)

    ticker = threading.Thread(target=tick)
    ticker.start()
    started = time.monotonic()
    with pytest.raises(kupcad.ScriptError):
        kupcad.build(FOREVER, timeout=0.3)
    ended = time.monotonic()
    building = False
    ticker.join()
    # A build holding the GIL would let the ticker tick only as the build began or ended, however
    # often a runner's timers wake it
    assert any(started + 0.05 < at < ended - 0.05 for at in ticks)


def test_threads_build_at_once() -> None:
    def printed(side: int) -> str:
        return kupcad.build(f"puts {side}\ncube({side})").report.output

    with ThreadPoolExecutor(max_workers=4) as pool:
        assert list(pool.map(printed, [1, 2, 3, 4])) == ["1\n", "2\n", "3\n", "4\n"]


def test_every_example_the_repository_ships_builds_with_its_defaults(
    examples: list[tuple[Path, str]],
) -> None:
    for path, format in examples:
        model = kupcad.build(path.read_text(encoding="utf-8"), format=format)
        assert model.data.startswith(b"<?xml" if format == "svg" else b"glTF"), path


def test_errors_are_kupcad_errors() -> None:
    assert issubclass(kupcad.ScriptError, kupcad.Error)
    assert issubclass(kupcad.Error, Exception)


def test_format_formats_as_kupcad_fmt_does() -> None:
    assert kupcad.format("cube( 1 )") == "cube(1)\n"
    assert kupcad.format("") == ""
    with pytest.raises(kupcad.ScriptError, match=r"^1:5: ") as failure:
        kupcad.format("x = )")
    # Nothing ran
    assert failure.value.report is None


def test_check_finds_what_kupcad_check_finds() -> None:
    finding = kupcad.check("x = 1\ncube(1)")[0]
    where = (finding.line, finding.column)
    assert (finding.rule, finding.severity, where) == ("unused-variable", "warning", (1, 1))
    assert kupcad.check("cube(1)") == []


def test_check_finds_a_syntax_error_as_a_finding_without_a_rule() -> None:
    finding = kupcad.check("x = )")[0]
    assert (finding.severity, finding.rule, finding.code) == ("error", None, "invalid-expression")


def test_params_reads_the_schema_kupcad_doc_prints() -> None:
    schema = kupcad.params("# @title Plate\nwidth = param(:width, default: 40)\ncube(width)")
    assert schema["meta"]["title"] == "Plate"
    assert [parameter["name"] for parameter in schema["parameters"]] == ["width"]
