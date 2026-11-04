from __future__ import annotations

import math
from concurrent.futures import ThreadPoolExecutor

import pytest
from conftest import DRAWINGS, EXAMPLES

import kupcad


def test_the_library_is_the_package_version() -> None:
    assert kupcad.library_version() == kupcad.__version__


def test_build_builds_the_model_in_every_format() -> None:
    for format in kupcad.FORMATS:
        model = kupcad.build("cube(10)", format=format)
        assert model.format == format
        assert model.data


def test_build_takes_the_parameters_by_name_and_keeps_what_the_script_prints() -> None:
    source = """width = param(:width, default: 5)
thread = param(:thread, default: :m3, validate: { in: [:m3, :m4] })
puts width, thread
cube(width)"""
    model = kupcad.build(source, params={"width": 20, "thread": "m4"})
    assert model.report.output == "20\nm4\n"


def test_build_reads_the_files_given_with_it() -> None:
    source = 'import { side } from "./lib/sizes.kup"\nputs side\ncube(side)'
    model = kupcad.build(source, files={"lib/sizes.kup": "def side = 12\nexport side"})
    assert model.report.output == "12\n"


def test_build_reports_what_the_script_warned_of_where() -> None:
    model = kupcad.build('cube(1)\nwarn("thin wall")\ncube(1)')
    assert model.report.warnings == (
        kupcad.RunWarning(message="thin wall", line=2, column=1, file=None),
    )


def test_a_script_that_fails_raises_where_with_what_it_printed_until_then() -> None:
    with pytest.raises(kupcad.ScriptError, match=r"^RuntimeError: Plate too thin$") as failure:
        kupcad.build('puts "before"\nraise "Plate too thin"')
    assert failure.value.report is not None
    assert failure.value.report.output == "before\n"
    with pytest.raises(kupcad.ScriptError, match=r"^2:5: "):
        kupcad.build("x = 1\ny = )")


def test_a_format_that_is_not_one_and_parameters_json_cannot_hold_are_value_errors() -> None:
    with pytest.raises(ValueError, match="'stp' isn't a format"):
        kupcad.build("cube(1)", format="stp")
    with pytest.raises(ValueError, match="JSON"):
        kupcad.build("cube(1)", params={"width": math.nan})


def test_the_memory_limit_stops_a_script_that_holds_more() -> None:
    with pytest.raises(kupcad.ScriptError, match=r"^OutOfMemoryError: "):
        kupcad.build("a = (1..2_000_000).to_a\ncube(1)", memory_limit=1_000_000)


def test_threads_build_at_once() -> None:
    with ThreadPoolExecutor(max_workers=4) as pool:
        outputs = list(
            pool.map(
                lambda side: kupcad.build(f"puts {side}\ncube({side})").report.output, [1, 2, 3, 4]
            )
        )
    assert outputs == ["1\n", "2\n", "3\n", "4\n"]


def test_every_example_the_repository_ships_builds_with_its_defaults() -> None:
    for path in sorted(EXAMPLES.glob("*.kup")):
        drawing = path.name in DRAWINGS
        model = kupcad.build(path.read_text(), format="svg" if drawing else "glb")
        assert model.data.startswith(b"<?xml" if drawing else b"glTF"), path


def test_format_formats_as_kupcad_fmt_does() -> None:
    assert kupcad.format("cube( 1 )") == "cube(1)\n"
    with pytest.raises(kupcad.ScriptError, match=r"^1:5: "):
        kupcad.format("x = )")


def test_check_finds_what_kupcad_check_finds() -> None:
    finding = kupcad.check("x = 1\ncube(1)")[0]
    where = (finding.line, finding.column)
    assert (finding.rule, finding.severity, where) == ("unused-variable", "warning", (1, 1))
    assert kupcad.check("cube(1)") == []


def test_params_reads_the_schema_kupcad_doc_prints() -> None:
    schema = kupcad.params("# @title Plate\nwidth = param(:width, default: 40)\ncube(width)")
    assert schema["meta"]["title"] == "Plate"
    assert [parameter["name"] for parameter in schema["parameters"]] == ["width"]
