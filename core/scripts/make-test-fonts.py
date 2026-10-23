"""Writes the small fonts in src/core/test_fonts/, which the font tests and the font fuzz
target's seeds read: made here from a few polygons, so they are KupCAD's own and small enough
to fuzz. Run `python3 scripts/make-test-fonts.py` from core/ with fontTools installed
(`pip install -r scripts/requirements.txt`), and commit what changes.

- kern-table.ttf: TrueType outlines, kerning in a `kern` table (format 0), no GPOS.
- gpos-kerning.otf: CFF outlines, kerning in GPOS: one glyph pair (format 1) and class pairs
  (format 2).
- unnamed.ttf: kern-table.ttf without a name table, a font that names itself nowhere.
- no-cmap.ttf: kern-table.ttf without a cmap table, a font that maps no character.
- no-outlines.ttf: kern-table.ttf without its glyf and loca tables, a font with no outlines.
"""

import pathlib

from fontTools.feaLib.builder import addOpenTypeFeaturesFromString
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.t2CharStringPen import T2CharStringPen
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib import newTable
from fontTools.ttLib.tables._k_e_r_n import KernTable_format_0

OUT = pathlib.Path(__file__).resolve().parent.parent / "src" / "core" / "test_fonts"
UNITS_PER_EM = 1000
# head's created and modified, in seconds since 1904: 2026-10-20
FIXED_TIMESTAMP = 3875299200
ASCENT, DESCENT = 800, -200

# Each glyph: its advance and its contours, clockwise outside, counter-clockwise for a hole
GLYPHS = {
    ".notdef": (500, [[(50, 0), (50, 700), (450, 700), (450, 0)]]),
    "space": (250, []),
    "A": (600, [[(0, 0), (300, 700), (600, 0)]]),
    "V": (600, [[(0, 700), (600, 700), (300, 0)]]),
    "T": (600, [[(0, 600), (0, 700), (600, 700), (600, 600), (350, 600), (350, 0), (250, 0), (250, 600)]]),
    "o": (500, [[(50, 0), (50, 500), (450, 500), (450, 0)], [(150, 100), (350, 100), (350, 400), (150, 400)]]),
    "l": (500, [[(200, 0), (200, 700), (300, 700), (300, 0)]]),
}
CMAP = {ord(" "): "space", ord("A"): "A", ord("V"): "V", ord("T"): "T", ord("o"): "o", ord("l"): "l"}

# The kern table's pairs, in font units
KERN_PAIRS = {("A", "V"): -100, ("V", "A"): -90, ("T", "o"): -80}

# GPOS: a glyph pair, and class pairs that also give V A and T o
FEATURES = """
languagesystem DFLT dflt;
languagesystem latn dflt;
@LEFT = [T V];
@RIGHT = [o A];
feature kern {
  pos A V -100;
  pos @LEFT @RIGHT -70;
} kern;
"""


def draw(pen, contours):
    for contour in contours:
        pen.moveTo(contour[0])
        for point in contour[1:]:
            pen.lineTo(point)
        pen.closePath()


def builder(family):
    fb = FontBuilder(UNITS_PER_EM, isTTF=family.endswith("TT"))
    fb.setupGlyphOrder(list(GLYPHS))
    fb.setupCharacterMap(CMAP)
    return fb


def finish(fb, family, path, drop=()):
    metrics = {name: (advance, min((x for c in contours for x, _ in c), default=0)) for name, (advance, contours) in GLYPHS.items()}
    fb.setupHorizontalMetrics(metrics)
    fb.setupHorizontalHeader(ascent=ASCENT, descent=DESCENT)
    fb.setupNameTable({"familyName": family, "styleName": "Regular"})
    fb.setupOS2(sTypoAscender=ASCENT, sTypoDescender=DESCENT, usWinAscent=ASCENT, usWinDescent=-DESCENT)
    fb.setupPost()
    # A font that lacks a table text needs
    for tag in drop:
        del fb.font[tag]
    # The same bytes on every run: no creation or modification time of today
    fb.font.recalcTimestamp = False
    fb.font["head"].created = fb.font["head"].modified = FIXED_TIMESTAMP
    fb.save(path)
    print(f"{path.name}: {path.stat().st_size} bytes")


def kern_table_font(path="kern-table.ttf", drop=()):
    family = "KupCAD Test TT"
    fb = builder(family)
    glyphs = {}
    for name, (_, contours) in GLYPHS.items():
        pen = TTGlyphPen(None)
        draw(pen, contours)
        glyphs[name] = pen.glyph()
    fb.setupGlyf(glyphs)
    kern = newTable("kern")
    kern.version = 0
    subtable = KernTable_format_0()
    subtable.version, subtable.coverage, subtable.format = 0, 1, 0
    subtable.kernTable = dict(KERN_PAIRS)
    kern.kernTables = [subtable]
    fb.font["kern"] = kern
    finish(fb, family, OUT / path, drop)


def gpos_font():
    family = "KupCAD Test CFF"
    fb = builder(family)
    charstrings = {}
    for name, (advance, contours) in GLYPHS.items():
        pen = T2CharStringPen(advance, None)
        draw(pen, contours)
        charstrings[name] = pen.getCharString()
    fb.setupCFF(family.replace(" ", ""), {"FullName": family}, charstrings, {})
    addOpenTypeFeaturesFromString(fb.font, FEATURES)
    finish(fb, family, OUT / "gpos-kerning.otf")


if __name__ == "__main__":
    OUT.mkdir(exist_ok=True)
    kern_table_font()
    kern_table_font("unnamed.ttf", drop=("name",))
    kern_table_font("no-cmap.ttf", drop=("cmap",))
    kern_table_font("no-outlines.ttf", drop=("glyf", "loca"))
    gpos_font()
