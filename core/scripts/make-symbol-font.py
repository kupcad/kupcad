"""Writes src/core/fonts/KupCADSymbols-Regular.ttf, the font `text()` draws a character from when
the font it draws in has none: the symbols of drawings, tolerances, panels and labels, taken from
three Noto fonts (SIL Open Font License 1.1, licenses/NotoSymbols-OFL.txt) and renamed, as a
font made from them should be. Run from core/ with fontTools installed
(`pip install -r scripts/requirements.txt`), the three source fonts in a folder:

    python3 scripts/make-symbol-font.py path/to/folder

and commit what changes. The sources, from google/fonts:

- ofl/notosansmath/NotoSansMath-Regular.ttf (Version 3.000), at 823468bd7825152bce2b8fd2cf740432ad2fce8d
- ofl/notosanssymbols/NotoSansSymbols[wght].ttf (Version 2.003), at 8b0a1d0f5983c89bc2b93f1b5fb55f9e252744b5
- ofl/notosanssymbols2/NotoSansSymbols2-Regular.ttf (Version 2.008), at the same commit

Each group's characters come from the first source that has them, in the group's order, so a
group's symbols match each other. A character no source has stops the script.
"""

import pathlib
import sys

from fontTools import subset
from fontTools.merge import Merger
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont

OUT = pathlib.Path(__file__).resolve().parent.parent / "src" / "core" / "fonts" / "KupCADSymbols-Regular.ttf"
SOURCES = {
    "math": "NotoSansMath-Regular.ttf",
    "symbols": "NotoSansSymbols[wght].ttf",
    "symbols2": "NotoSansSymbols2-Regular.ttf",
}
# head's created and modified, in seconds since 1904: 2026-10-31, so the file is the same each run
FIXED_TIMESTAMP = 3876249600

# (group, its characters, the sources to take them from, first first)
GROUPS = [
    # Dimensions and tolerances (ISO 1101, ASME Y14.5): diameter, the tolerances' symbols,
    # counterbore, countersink, depth, arc length, square, and their circled modifiers
    ("drawing", "⌀⌖⏥⏤○⌭⌒⌓∥⊥∠◎⌯↗⌰⌴⌵↧⌲⌳⌢□ⓂⓁⓅⒻⓉⓈⓊ", ["math", "symbols", "symbols2"]),
    ("math", "±∓×÷°′″≈≠≤≥∞√∅∆π∑Ω", ["math", "symbols", "symbols2"]),
    ("arrows", "←↑→↓↔↕↖↗↘↙⇄⇅↺↻⟲⟳⇐⇒", ["math", "symbols", "symbols2"]),
    # Earth, power, standby, high voltage, direct and alternating current
    ("electrical", "⏚⏻⏼⏽⭘⚡⎓∿⏦⌁", ["symbols2", "symbols", "math"]),
    ("signs", "✓✔✗✘★☆⚠♻☢☣⚙⌘⏏⏎⇧⌫⌥⌃⏵⏸⏹⏺☀❄♨", ["symbols2", "symbols", "math"]),
    ("shapes", "■□▲△▼▽●○◆◇◉", ["symbols2", "math", "symbols"]),
]

NAMES = {
    0: "Copyright 2022 The Noto Project Authors (https://github.com/notofonts/math, "
    "https://github.com/notofonts/symbols). A subset of Noto Sans Math, Noto Sans Symbols "
    "and Noto Sans Symbols 2, made for KupCAD.",
    1: "KupCAD Symbols",
    2: "Regular",
    3: "1.000;KupCAD;KupCADSymbols-Regular",
    4: "KupCAD Symbols Regular",
    5: "Version 1.000",
    6: "KupCADSymbols-Regular",
    13: "This Font Software is licensed under the SIL Open Font License, Version 1.1.",
    14: "https://openfontlicense.org",
}


def assign(fonts):
    """Each source's characters: every group's, each from the first of its sources that has it."""
    taken = {name: [] for name in SOURCES}
    seen = set()
    for group, chars, order in GROUPS:
        for char in chars:
            if char in seen:
                continue
            seen.add(char)
            source = next((name for name in order if ord(char) in fonts[name].getBestCmap()), None)
            if source is None:
                sys.exit(f"{group}: no source has {char} (U+{ord(char):04X})")
            taken[source].append(ord(char))
    return taken


def cut(font, codepoints):
    """`font` holding only `codepoints`' glyphs, their outlines and advances: no layout, no hints."""
    options = subset.Options()
    options.layout_features = []
    options.hinting = False
    options.glyph_names = False
    options.notdef_outline = True
    options.drop_tables += ["GSUB", "GPOS", "GDEF", "MATH", "BASE", "STAT", "vhea", "vmtx", "gasp", "DSIG"]
    subsetter = subset.Subsetter(options)
    subsetter.populate(unicodes=codepoints)
    subsetter.subset(font)
    return font


def main(folder):
    folder = pathlib.Path(folder)
    fonts = {name: TTFont(folder / file) for name, file in SOURCES.items()}
    # The variable font at its Regular weight: a static font, as the others are
    fonts["symbols"] = instantiateVariableFont(fonts["symbols"], {"wght": 400})
    taken = assign(fonts)
    parts = []
    for name, codepoints in taken.items():
        if not codepoints:
            continue
        path = OUT.with_name(f".{name}.ttf")
        cut(fonts[name], codepoints).save(path)
        parts.append(path)
    merged = Merger().merge([str(path) for path in parts])
    for path in parts:
        path.unlink()

    name_table = merged["name"]
    name_table.names = []
    for name_id, text in NAMES.items():
        name_table.setName(text, name_id, 3, 1, 0x409)
    merged["head"].created = merged["head"].modified = FIXED_TIMESTAMP
    merged["OS/2"].achVendID = "    "
    # Saving stamps the time into head.modified unless told not to
    merged.recalcTimestamp = False
    merged.save(OUT)

    saved = TTFont(OUT)
    covered = saved.getBestCmap()
    wanted = {char for _, chars, _ in GROUPS for char in chars}
    missing = [char for char in wanted if ord(char) not in covered]
    if missing:
        sys.exit(f"the merged font lacks {''.join(missing)}")
    print(f"{OUT.name}: {len(wanted)} symbols, {OUT.stat().st_size} bytes")
    for name, codepoints in taken.items():
        print(f"  from {SOURCES[name]}: {''.join(map(chr, codepoints))}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
